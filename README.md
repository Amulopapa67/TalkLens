# TalkLens

**[中文](#中文) · [English](#english)**

---

## 中文

TalkLens 是一个 macOS 菜单栏小工具。它以**只读**方式读取已经打开的 KakaoTalk for Mac 聊天窗口，用 macOS 自带的 **Apple 翻译**（本机、离线）把韩语消息翻成简体中文（目标语言可改），译文显示在贴靠聊天窗口的半透明侧栏里。

> ⚠️ **非官方项目，与 Kakao Corp. 没有任何关系**，也没有得到 Kakao 的认可或支持。"KakaoTalk" 是 Kakao Corp. 的商标，这里只用来说明兼容对象。
>
> - TalkLens **只读**：不发送、不点击、不输入、不滚动，也不激活、启动或关闭 KakaoTalk。
> - 它依赖 KakaoTalk 的辅助功能（Accessibility）界面结构，**KakaoTalk 更新后可能失效**。
> - **使用者自担风险。** 软件按 MIT 许可"原样"提供，不附带任何担保。

### 功能

- 菜单栏图标：启用/暂停翻译、显示/隐藏侧栏、常驻显示、设置、引导、关于、退出。
- 侧栏贴在聊天窗口右侧（空间不够时贴左侧或内嵌），跟随窗口移动、缩放、最小化、切换聊天。
- 每条消息显示作者 · 时间、译文；原文可折叠；新消息淡入；可一键复制译文。
- 不翻的内容：纯表情、ㅋㅋ/ㅎㅎ 这类字母缩写（显示词表注释）、链接、数字、已经是目标语言的消息。
- 内置校园/实验室/俚语词表（랩미팅 = 组会、휴강 = 停课 …），以 chip 形式显示在译文下方；可以编辑自己的词表。
- 设置：目标语言、显示原文、字号、透明度、贴靠位置、侧栏宽度、词表开关、开机启动。

### 系统要求

- macOS 15 或更新版本（Apple Silicon 或 Intel）。macOS 26+ 体验最好（翻译不需要隐藏窗口）。
- KakaoTalk for Mac。
- 系统设置 → 通用 → 语言与地区 → **翻译语言**：下载「韩语」和目标语言（如「中文（简体）」）。TalkLens 首次运行时也会引导你下载。

### 安装

1. 从 Releases 下载 `TalkLens-<版本>.zip`，核对 `.sha256`，解压后把 `TalkLens.app` 拖进「应用程序」。
2. 首次打开时，如果 Gatekeeper 提示"无法验证开发者"：在 Finder 里**右键 → 打开**，或到 系统设置 → 隐私与安全性 底部点「仍要打开」。也可以在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/TalkLens.app
   ```

3. 授予**辅助功能**权限：系统设置 → 隐私与安全性 → 辅助功能 → 打开 TalkLens。授权后无需重启。

### 从源码构建

需要 Swift 6 工具链（Xcode 16+ 或 Command Line Tools）。

```bash
swift build -c release
./scripts/build_app.sh          # 生成并签名 build/TalkLens.app
./scripts/verify.sh             # 完整验收（构建、测试、只读守卫、回放、性能、打包…）
```

`build_app.sh` 优先使用钥匙串里的 "Apple Development"/"Developer ID" 证书签名，这样重新构建后辅助功能授权不会丢；没有证书时用 ad-hoc 签名，可能每次重建都要重新授权。

### 隐私

- **零网络**：TalkLens 不发起任何网络请求，翻译全部在本机完成。
- 消息文本**只在内存里**；翻译缓存是内存 LRU，退出即清空；不写任何文件。
- 日志只记录数量、长度、耗时和错误码，**不记录消息原文或聊天名**。没有遥测。
- 详见 [PRIVACY.md](PRIVACY.md)。

### 它不会做什么

不碰 KakaoTalk 的网络协议（LOCO）；不读取、不解密 KakaoTalk 的本地数据库或缓存；不注入、不 hook、不使用私有框架；不截屏；不模拟键盘鼠标；不写剪贴板（唯一例外：你点击"复制译文"时）。

### 已知限制

- 只翻译屏幕上**可见**的消息（KakaoTalk 的列表可能虚拟化，TalkLens 也不会替你滚动）。
- Apple 翻译对口语和俚语的效果一般，词表 chip 和可展开的原文用来弥补。
- 编辑或删除过的消息会被当作新消息处理。

### 许可与致谢

MIT 许可，见 [LICENSE](LICENSE)。`Sources/KakaoAX/` 中部分代码改写自 [kmsg](https://github.com/channprj/kmsg)（MIT，Copyright (c) 2026 Park Hee Chan），只保留了只读部分，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

## English

TalkLens is a macOS menu bar companion that **reads** the KakaoTalk for Mac chat window you already have open, translates Korean messages on-device with **Apple Translation** (offline; target language configurable, default Simplified Chinese), and shows the translations in a translucent sidebar docked next to the chat window.

> ⚠️ **TalkLens is an unofficial project and is not affiliated with Kakao Corp.**, nor endorsed or supported by it. "KakaoTalk" is a trademark of Kakao Corp. and is used here only to describe compatibility.
>
> - TalkLens is **read-only**: it never sends, clicks, types or scrolls, and never activates, launches or quits KakaoTalk.
> - It relies on KakaoTalk's accessibility (AX) structure and **may break when KakaoTalk updates**.
> - **Use at your own risk.** The software is provided "as is" under the MIT License, without warranty of any kind.

### Features

- Menu bar item: enable/pause translation, show/hide sidebar, pin sidebar, settings, onboarding, about, quit.
- Sidebar docks to the right of the chat window (left or inset when there is no room) and follows moves, resizes, minimize and chat switches.
- Each message shows author · time and the translation; the original is collapsible; new messages fade in; one-click copy of a translation.
- Not machine-translated: emoji-only, jamo shorthand like ㅋㅋ/ㅎㅎ (shown with a glossary note), links, numbers, messages already in the target language.
- Built-in campus/lab/slang glossary shown as chips under translations; user glossary is editable.
- Settings: target language, show original, font size, opacity, dock side, sidebar width, glossary on/off, launch at login.

### Requirements

- macOS 15 or later. macOS 26+ recommended (UI-less translation sessions).
- KakaoTalk for Mac.
- System Settings → General → Language & Region → **Translation Languages**: download Korean and your target language. TalkLens offers to start the download on first run.

### Install

1. Download `TalkLens-<version>.zip` from Releases, check the `.sha256`, unzip and move `TalkLens.app` to Applications.
2. If Gatekeeper says the developer cannot be verified: **right-click → Open** in Finder, or click "Open Anyway" at the bottom of System Settings → Privacy & Security. Or run `xattr -dr com.apple.quarantine /Applications/TalkLens.app`.
3. Grant **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable TalkLens. No restart needed.

### Build from source

Requires a Swift 6 toolchain (Xcode 16+ or Command Line Tools).

```bash
swift build -c release
./scripts/build_app.sh          # builds and signs build/TalkLens.app
./scripts/verify.sh             # full acceptance run
```

### Privacy

- **No network access** — translation happens entirely on device.
- Message text stays **in memory only**; the translation cache is an in-memory LRU cleared on quit; nothing is written to disk.
- Logs contain only counts, lengths, durations and error codes — **never message text or chat names**. No telemetry.
- See [PRIVACY.md](PRIVACY.md).

### What it never does

No KakaoTalk network protocol (LOCO); no reading or decrypting KakaoTalk's local databases or caches; no injection, hooking or private frameworks; no screen capture; no synthetic keyboard/mouse events; no clipboard writes except when you click "copy translation".

### Known limitations

- Only **visible** messages are translated (the list may be virtualized and TalkLens never scrolls for you).
- Apple Translation is weak on slang; glossary chips and the expandable original help.
- Edited or deleted messages are treated as new messages.

### License & credits

MIT — see [LICENSE](LICENSE). Parts of `Sources/KakaoAX/` are derived from [kmsg](https://github.com/channprj/kmsg) (MIT, Copyright (c) 2026 Park Hee Chan), reduced to its read-only subset; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
