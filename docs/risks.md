# 风险清单

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | KakaoTalk 更新改了 AX 结构 | 读不到或读错消息 | • 解析写成多启发式打分（沿用 kmsg 思路）<br>• fixtures 标注 kakaoVersion<br>• `tlctl probe` 在 verify 里跑<br>• ax-map.md 记录版本差异 |
| R2 | 列表虚拟化，屏幕外的行不在树里 | 只能翻可见消息 | 产品就定义为"翻可见的"，侧栏跟着窗口可见区域走 |
| R3 | KakaoTalk 不发内容类 AX 通知 | 只能轮询 | 只在前台时 1 s 兜底轮询，读取限定在 transcript 子树，批量取属性 |
| R4 | 重建后 TCC 辅助功能权限丢失 | 开发时反复授权 | 用固定的 Apple Development 签名；dev 时用终端权限跑 tlctl |
| R5 | 翻译语言未安装，或 macOS < 26 | 无 UI 拿不到 session | 用 SwiftUI 宿主视图兜底 + `prepareTranslation()` 引导下载；selftest 给出明确 SKIP 原因 |
| R6 | Apple 翻译口语/俚语效果差 | 理解偏差 | glossary chips + 原文可展开；不追求准确 |
| R7 | Swift 6 严格并发与 AX C 回调冲突 | 编译难或数据竞争 | 回调只做 `Task { @MainActor in … }` 转发；AX 读取集中在一个 actor |
| R8 | 浮层抢焦点或挡住输入框 | 体验差 | 非激活面板，`canBecomeKey = false`，用输入框 frame 避让 |
| R9 | 多屏、全屏、Spaces、Stage Manager | 位置错乱 | 坐标换算单测；`.fullScreenAuxiliary`；LIVE_CHECKLIST 覆盖 |
| R10 | 隐私：开发过程中 AI 看到真实聊天 | 违背同学/老师意愿 | 默认脱敏 + 标题白名单（只限 나와의 채팅）+ settings.json deny 截屏 + 红线 |
| R11 | Kakao 条款 / 商标 | 被投诉 | 只读、无自动化、无协议；不用 Kakao 名称和图标；README 免责 |
| R12 | 只有 Command Line Tools，没有 Xcode | XCTest 不可用 | 用 Swift Testing；不行再请 Lipper 装 Xcode |
