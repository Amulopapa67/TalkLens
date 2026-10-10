# KakaoTalk for Mac — AX 结构图

> 每条结论标 **[观察]**（附命令和脱敏输出摘要）或 **[推断]**。kmsg 文档里的记录只是起点，标为 **[kmsg]**。
> 观察都来自脱敏 dump（`swift tools/kakao_ax_probe.swift dump`），以及 Lipper 的 나와의 채팅 白名单录制（`tlctl record --show-text-for …`），没有读过其他聊天的原文。

## 环境

| 项 | 值 |
|---|---|
| KakaoTalk 版本 | 26.8.0（界面语言：English） |
| macOS 版本 | 27.2（26B5091g），arm64 |
| 记录日期 | 2026-10-10 |

## 主窗口（好友 / 聊天列表）

- **[观察]** `AXWindow` 的 title 是 `KakaoTalk`。直接子节点里有 `AXButton` identifier `friends` / `chatrooms` / `more` → `KakaoChatReader.isChatWindow` 据此排除主窗口。
- **[观察]** 聊天列表：`AXScrollArea(_NS:101) → AXTable → AXRow(AXTableRow) → AXCell → [AXButton 44×44（头像，带 description）, AXStaticText（聊天名）, AXStaticText "Count Label"（未读数）, AXStaticText（时间/日期）, AXScrollArea → AXTextArea（最后一条预览）]`。
- **[观察]** 列表 rows=17、visibleRows=9：**屏幕外的行也在 AX 树里**（AXTable 高 1260，外层 ScrollArea 只有 648）。

## 聊天窗口

| 问题 | 结论 | 证据 |
|---|---|---|
| transcript 容器路径 | **[观察]** 窗口直接子节点 `AXScrollArea(_NS:29) → AXTable(_NS:33) → AXRow(subrole AXTableRow) → AXCell`；表格最后一个子节点是 `AXColumn`（AutomaticTableColumnIdentifier.0） | 脱敏 dump：rows=8 visibleRows=8 |
| 输入框 | **[观察]** 窗口直接子节点 `AXScrollArea(_NS:47) → AXTextArea(_NS:51)`，description 是占位文字（"Enter a message"），无 value；下方有 3 个 26×26 的 AXButton（Emoticons ⌘E / Send Files ⌘O / More Features）和一个带 title 的 Send 按钮 | self-chat 录制 |
| 窗口头部 | **[观察]** AXButton 40×40（Profile）、AXStaticText（聊天名，value 和 help 都是标题）、Search / Chatroom Archives / Menu 三个 32×32 按钮、AXSlider（窗口透明度，value 1） | self-chat 录制 |
| 一行的子结构（文字消息） | **[观察]** `AXCell → [AXImage（气泡背景，包住正文）, AXTextArea（正文，value）]` | dump：AXImage [650,331,286,31] 包住 AXTextArea [655,339,273,16] |
| 正文在哪个属性 | **[观察]** AXTextArea 的 `AXValue`；多行消息就是一个 AXTextArea，value 里带 `\n` | self-chat：第 23 条 4 行完整读出 |
| 时间 label、AXHelp 日期 | **[观察]** 只在**同一分钟一组消息的最后一条**上有 `AXStaticText`：value = `6:01 PM`（数字和 PM 之间是 U+202F 窄不换行空格），help = `10/10/26`（美式 M/D/YY）。我发的消息，时间在气泡左边 | self-chat 录制；dump 中 value 7 字、help 8 字 |
| "我发的"怎么判断 | **[观察]** 气泡右缘贴近消息区右缘（936 vs 946）。长气泡的 midX 比例约 0.6，落在 kmsg 0.56/0.62 阈值之间的不确定区 → 改为先看边缘对齐（D-015） | dump frames |
| 日期分隔行 | **[观察]** `AXCell → AXButton 200×28`，**没有 title/value/description**；屏幕上显示 "Saturday, October 10, 2026"，但 AX 里读不到文字 → 跳过 | dump + Lipper 截图 |
| 表格末尾 | **[观察]** 一个空的 AXCell（高 15），是占位行，跳过 | dump |
| 作者名（别人的消息） | **[推断]** 按 kmsg：一组的第一条有头像（AXButton/AXImage 约 36–40pt，靠左）和作者 AXStaticText。还没观察到（나와의 채팅 里只有自己）| 待核对 |
| 系统消息（进出群等） | **[推断]** 居中的 AXStaticText，或和日期分隔一样是不带文字的按钮 | 待核对 |
| 图片 / 链接 / 文件 / 表情贴图 | **[推断]** 大 AXImage（不包住 AXTextArea）= 图片；AXLink = 链接；"Save" 按钮 + 文件名 = 文件 | 待核对 |
| 长消息折叠（"전체보기"） | **[推断]** 可能有一个按钮；目前只读 AXTextArea 的可见文本 | 待核对 |
| 回复 / 引用消息 | 未知 | 待核对 |
| 虚拟化 | **[观察]** 聊天列表表格包含屏幕外的行（rows > visibleRows）。聊天窗口这次 rows = visibleRows = 8（消息少）。解析器默认只取和消息区可见范围相交的行 | dump |
| 新消息到达时的通知 | **[观察]** 消息区 AXTable 上的 `AXRowCountChanged`，70 ms 内连发 3 次；防抖后 1 次读取就能拿到新增的那条（diff appended=1）。**滚动聊天记录不发任何通知**，靠 App 的 1 s 兜底轮询（廉价检查）发现可见范围的变化。提示框/弹出层会在应用元素上发 `AXWindowCreated` | `tlctl watch --seconds 90`：AXRowCountChanged=3、AXWindowCreated=3 |
| 移动 / 缩放 / 最小化的通知 | **[观察]** 拖动窗口：AXWindow 上的 `AXMoved`，约每 100 ms 一次；缩放：`AXResized`，约 60 Hz（2 s 里 111 次）；最小化：`AXFocusedWindowChanged` + `AXMainWindowChanged` + `AXWindowMiniaturized`。侧栏跟随以事件驱动为主 | `tlctl watch --seconds 45`：AXMoved=11、AXResized=111、AXWindowMiniaturized=1 |
| 单次读取耗时 | **[观察]** 8 行：locate 0.06 ms + parse 1.1–1.3 ms（`tlctl probe --summary`）；合成 205 行：parse p95 ≈ 4 ms（`tlctl bench`） | probe / bench |

## 与 kmsg 记录的差异（汇总见 D-015）

1. 气泡背景是 AXImage，kmsg 的"≥48×48 的图片 = 图片附件"会误判，改为"包住正文的 AXImage 不算图片"。
2. 时间只标在一组的最后一条，所以往回填。
3. 我发的长气泡需要用边缘对齐判断方向。
4. 英文界面的时间和日期格式（`6:01 PM`、`10/10/26`）。
