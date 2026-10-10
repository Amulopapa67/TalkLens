# 架构 — TalkLens

> 状态：设计草案（2026-10-10，由 Cowork 里的 Claude 起草）。M0 实测后由 Claude Code 修订。凡标 [待 M0 核对] 的都还没在真机上验证。

## 1. 数据流

```
 KakaoTalk for Mac (com.kakao.KakaoTalkMac)
        │  macOS Accessibility (read-only IPC)
        ▼
 ┌──────────────────┐   events (debounced 120 ms)   ┌──────────────────┐
 │ WindowTracker    │ ─────────────────────────────▶│ AXReader (actor) │
 │ NSWorkspace +    │   frontmost / focused window  │ KakaoAX: resolve │
 │ AXObserver       │   moved / resized / rows      │ transcript, read │
 └──────────────────┘                                │ rows → messages  │
        │ window frame                               └────────┬─────────┘
        ▼                                                     │ TranscriptSnapshot
 ┌──────────────────┐                               ┌─────────▼─────────┐
 │ OverlayPanel     │◀──── SidebarViewModel ◀───────│ TalkLensCore      │
 │ NSPanel + SwiftUI│      (@MainActor, rows)       │ identity + diff + │
 └──────────────────┘                               │ preprocess+gloss  │
                                                    └─────────┬─────────┘
                                                              │ TranslationJob[]
                                                    ┌─────────▼─────────┐
                                                    │ TranslationService│
                                                    │ (actor) priority, │
                                                    │ dedupe, batch,    │
                                                    │ cancel, LRU cache │
                                                    └─────────┬─────────┘
                                                              │
                                              AppleTranslationEngine / MockEngine
```

## 2. 模块（SwiftPM targets）

| Target | 类型 | 依赖 | 说明 |
|---|---|---|---|
| `KakaoAX` | library | ApplicationServices, AppKit(仅 NSRunningApplication) | kmsg 只读子集 + `AXNodeLike` |
| `TalkLensCore` | library | Foundation, NaturalLanguage | 纯逻辑，可在任何线程，不 import AppKit |
| `TalkLensTranslate` | library | TalkLensCore, Translation, SwiftUI(宿主视图) | 引擎与调度 |
| `TalkLensApp` | executable | 以上全部, AppKit, SwiftUI, ServiceManagement | 菜单栏 App（`LSUIElement`） |
| `tlctl` | executable | KakaoAX, TalkLensCore, TalkLensTranslate | 开发/验收 CLI |
| `*Tests` | test | 对应 library | Swift Testing 优先 |

## 3. kmsg 只读子集（Sources/KakaoAX）

来源：`third_party/kmsg-upstream`，commit `54cbff7`（2026-09-21），MIT。

| kmsg 文件 | 处理 | 去掉的东西 |
|---|---|---|
| `Accessibility/UIElement.swift` | 改写为 `AXElement` + `LiveAXNode` | `setAttribute`、`performAction`、`press` |
| `Accessibility/AXConstants.swift`、`AXError+Extension.swift` | 原样 + 文件头 | — |
| `Accessibility/AccessibilityPermission.swift` | 保留检查 + 打开系统设置对应页 | `activateFileViewerSelecting` |
| `KakaoTalk/KakaoTalkApp.swift` | 精简为 `KakaoProcess`：找进程、app element、windows、版本 | `launch`、`activate`、`terminate`、open 命令 |
| `KakaoTalk/MessageContextResolver.swift` | 只保留 background-safe 路径：找输入框位置与 transcript root | `kakao.activate()`、`focusWithVerification`、`AXActionRunner` |
| `KakaoTalk/TranscriptReader.swift` | 解析逻辑改为对 `AXNodeLike` 泛型 | runner 依赖 |
| `Accessibility/AXPathCache.swift` | 可选：只做内存缓存 | 落盘 |
| `Commands/WatchCommand.swift` | 不拷代码，只借鉴"快照重叠比对"思路，在 `TranscriptDiffer` 里重写 | — |
| 其余（Auth、Send*、AXActionRunner、ChatWindowResolver、Update、MCP） | **不引入** | — |

```swift
// Sketch — final shape decided in M1.
public protocol AXNodeLike {
    var role: String? { get }
    var subrole: String? { get }
    var identifier: String? { get }
    var title: String? { get }
    var value: String? { get }
    var nodeDescription: String? { get }
    var help: String? { get }
    var frame: CGRect? { get }        // AX global coords (top-left origin)
    var children: [Self] { get }
}
```

## 4. TalkLensCore

### 4.1 模型

```swift
public struct ChatMessage: Hashable, Sendable {
    public let id: MessageID          // stable within a chat, see 4.2
    public let author: String?        // nil = me (right side) or system
    public let isMine: Bool
    public let isSystem: Bool         // join/leave, date divider, deleted, etc.
    public let timeRaw: String?       // "오후 3:12"
    public let date: String?          // "2026-10-10" from AXHelp when available
    public let body: String
    public let attachments: AttachmentSummary   // image/link/file counts only
    public let frame: CGRect?         // for S1 inline mode
}
```

### 4.2 消息身份（KakaoTalk 不给 message id）

- `baseKey = sha256(chatKey ‖ author ‖ date ‖ timeRaw ‖ normalizedBody)` 取前 16 hex。
- 同一快照里 baseKey 重复（同人同分钟发同样内容）时，加序号 `#k`（从上到下）。
- `chatKey` = 窗口标题的 hash。只在内存里用，日志里只出现 hash 前 6 位。
- 已知限制：编辑或删除消息会让 key 变化，这类消息当作新消息处理即可。

### 4.3 增量 diff（TranscriptDiffer）

- 输入：上一快照的 keys、当前快照的 keys。
- 输出：
  - `appended`：底部新增；
  - `prepended`：用户往上滚，顶部新增；
  - `removed`：滚出视野或被删；
  - `unchanged`。
- 算法：找最长的"后缀 = 前缀"重叠（O(n) 滑窗 + hash）。找不到重叠时（换了聊天、跳到很远）视为 reset。
- 翻译驱动：当前**可见集合**里没有译文的都要翻；优先级是 appended > 可见底部 > 可见顶部 > prepended。

### 4.4 预处理（ChatPreprocessor）

每条消息依次判断：

1. **规范化**：去掉零宽字符，合并空白，保留换行。
2. **分类**：
   - `system` → 不翻，显示原样（或 glossary 注释）。
   - `emojiOnly`、`jamoOnly`（ㅋㅋ/ㅎㅎ/ㅠㅠ/ㅇㅋ…）→ 不送 MT，直接查 glossary 给短注释。
   - `urlOnly` / `numberOrTimeOnly` → 不翻。
   - `alreadyTarget`：没有 Hangul，且 `NLLanguageRecognizer` 判定 ≠ ko → 不翻。
   - 其余 → `translate`。判定条件：Hangul 字符占字母的比例 ≥ 0.3；韩英混写也算。
3. **切分**：超过 1000 字的消息按换行和句号切块，逐块翻译后再拼回。
4. **glossary**：
   - 最长匹配优先，结果作为 chip 显示在译文下方，例如 `랩미팅 = 组会`。
   - 只有 `expand: true` 的条目（如 ㄱㄱ→고고）会在送翻译前替换。
   - `@이름` 提及和 URL 用占位保护，翻译后放回。占位格式要在 M2 测 Apple 翻译能否原样保留；保不住就改成"切段翻译 + 拼接"。

### 4.5 其它

- `TimeLabelParser`：识别 `오전/오후 h:mm`、`上午/下午 h:mm`、`AM/PM`、`HH:mm`、`YYYY. M. D.`、`M월 D일`、`YYYY-MM-DD`(AXHelp)。
- `LRUCache<Key, Value>`：key 为 `(engineID, src, tgt, normalizedText)`，容量默认 2000，纯内存。
- `Redactor`：所有日志、CLI 默认输出都经过它，把文本替换为 `<text len=N ko>`。

## 5. TalkLensTranslate

```swift
public protocol TranslationEngine: Sendable {
    var id: String { get }                         // "apple", "mock"
    func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus
    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult]
}
public enum EngineStatus: Sendable { case ready, needsDownload, unsupported(String) }
```

### AppleTranslationEngine

- **macOS 26+ 且 `.installed`**：用 `TranslationSession(installedSource:target:)`。26.4+ 时加 `preferredStrategy: .lowLatency`，由 `#available` 判断。
- **其它情况**：用 `TranslationHost`，即一个 0×0、不可见、不激活的 NSPanel，里面放 SwiftUI 视图 `.translationTask(config) { session in for await job in jobs { … } }`。job 通过 `AsyncStream` 送进来，结果用 continuation 回传。
- **需要下载语言时**：在设置或引导窗口里调用 `session.prepareTranslation()`，让系统弹出下载框（必须有可见 UI）。
- **批量**：`translations(from:)`，每批 ≤ 16 条或攒 50 ms。
- **取消**：切换聊天时取消旧聊天未完成的 job（`Task.cancel` + 结果丢弃）。

### MockEngine

确定性输出 `"[mock→zh-Hans] " + text`，供 replay/golden 和单测使用。

### TranslationService（actor）

负责优先队列、同文去重（in-flight map）、批量、取消、缓存、按条打点（只记耗时）。

## 6. TalkLensApp

### 6.1 WindowTracker

- `NSWorkspace.didActivateApplicationNotification` / `didTerminateApplicationNotification`：判断 KakaoTalk 是否在前台、是否退出。
- app element 上的 AXObserver：`kAXFocusedWindowChanged`、`kAXMainWindowChanged`、`kAXWindowCreated`。
- 当前聊天窗口上：`kAXMoved`、`kAXResized`、`kAXUIElementDestroyed`、`kAXWindowMiniaturized/Deminiaturized`、`kAXTitleChanged`。
- transcript 容器上：M0 里 `watch` 实测会触发的通知（候选：`AXRowCountChanged`、`AXCreated`、`AXValueChanged`、`AXLayoutChanged`）[待 M0 核对]。
- 兜底轮询：KakaoTalk 在前台且 5 s 内没收到内容事件时，每 1 s 读一次；不在前台时不轮询，重新激活时读一次。
- 防抖：内容事件 120 ms；移动/缩放事件直接驱动面板（≤ 100 ms）。

### 6.2 OverlayPanel

- 结构：`final class OverlayPanel: NSPanel`，`canBecomeKey/Main = false`，`.nonactivatingPanel`，透明背景加 `NSVisualEffectView`。
- 层级：KakaoTalk 在前台时用 `.floating`；否则隐藏（设置项"常驻"可改为 `.normal` 并跟随）。
- 贴靠：默认右侧外贴，宽 320 pt（可调）。右侧到屏幕边缘不足时贴左侧；两边都不够时内嵌在窗口右缘，并避开底部输入框（用 MessageContextResolver 得到的输入框 frame）。
- 坐标换算：`nsY = NSScreen.screens[0].frame.maxY - axY - h`，再用 `NSScreen.screens.first { $0.frame.intersects(rect) }` 约束在目标屏内。

### 6.3 侧栏 UI（SwiftUI in NSHostingView）

- 每行：作者 · 时间（小字）／译文（主字号）／原文（可折叠，次要色）／glossary chips。
- "我发的"右对齐或淡色。系统消息居中灰色。
- 底部吸附：用户没手动上滚侧栏时自动跟到最新。
- 菜单栏：`MenuBarExtra` 或 `NSStatusItem`，二选一由 ui-dev 定（D-xxx）。

### 6.4 设置与引导

- 设置窗口（SwiftUI `Settings` 或独立窗口）用 `NSApp.activate` 激活**本 App**。
- 权限引导：`AXIsProcessTrustedWithOptions(prompt: true)`，再打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`。

## 7. tlctl（verify.sh 依赖这些契约，改动要同步脚本）

| 命令 | 行为 | 退出码 |
|---|---|---|
| `tlctl probe [--summary]` | 真机：找 KakaoTalk、聊天窗口、transcript root，打印脱敏摘要（窗口数、行数、解析出的消息数、耗时） | 0 OK / 3 SKIP（未运行、无聊天窗口、无权限，打印原因）/ 1 FAIL |
| `tlctl watch --seconds N` | 真机：打印 AX 事件和 diff 结果（脱敏） | 0 / 3 / 1 |
| `tlctl record --out F.axjson [--show-text-for TITLE]` | 录当前聊天窗口子树。原文只在标题命中 `TITLE` 且该标题在 `.lens-dev.json` allowlist 里时保留，否则脱敏 | 0 / 3 / 1 |
| `tlctl replay <dir\|file> --engine mock [--golden DIR] [--update-golden]` | 离线：RecordedAXNode → 解析 → 预处理 → MockEngine，与 golden 比对 | 0 全一致 / 1 有差异（打印 diff） |
| `tlctl bench <dir> [--iterations 50]` | 离线：解析与 diff 的 p50/p95 | 0 在预算内 / 1 超预算 |
| `tlctl selftest --engine apple --source ko --target zh-Hans --input F` | 用 Apple 翻译翻 F 中每行（合成句子，可打印），输出 p50/p95 延迟 | 0 OK / 3 SKIP（OS 不支持、语言未安装，打印原因和解决办法）/ 1 FAIL |

## 8. fixtures 格式

**`fixtures/snapshots/<name>.axjson`**

```json
{
  "meta": {"source": "self-chat|synthetic", "kakaoVersion": "…", "macOS": "…", "recordedAt": "…", "note": "…"},
  "window": {"title": "<redacted or allowlisted>", "frame": [x, y, w, h]},
  "root": {"role": "AXScrollArea", "subrole": null, "title": null, "value": null,
           "description": null, "help": null, "frame": [x, y, w, h], "children": [ … ]}
}
```

**`fixtures/golden/<name>.json`**

- 内容：解析结果数组（author、isMine、isSystem、timeRaw、date、body、attachments）+ 预处理决策 + MockEngine 输出。
- 由 `tlctl replay --update-golden` 生成，人工审阅后提交。
- golden 改动必须在 journal 里说明原因。

## 9. 测试分层

| 层 | 依赖真机？ | 例子 |
|---|---|---|
| 单元 | 否 | TimeLabelParser、ChatPreprocessor 分类、glossary 最长匹配、LRU、MessageID 去重序号、Differ 各种重叠、坐标换算（含多屏） |
| replay | 否 | 每个 .axjson → golden |
| 引擎 | 是（本机翻译语言） | `tlctl selftest` |
| 真机 | 是（KakaoTalk + 权限） | `tlctl probe`、LIVE_CHECKLIST |
