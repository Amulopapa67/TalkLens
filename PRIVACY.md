# Privacy / 隐私说明

## 中文

TalkLens 处理的是别人发给你的聊天消息，这些人并没有同意让任何第三方看到它们。所以 TalkLens 的设计原则是：**消息不离开这台 Mac 的内存。**

| 项目 | TalkLens 的做法 |
|---|---|
| 网络 | 不发起任何网络请求。代码里没有 URLSession、Network.framework、WebKit（`scripts/guard_readonly.sh` 会检查）。 |
| 翻译 | 使用 Apple Translation 框架，模型在本机运行。语言模型由 macOS 自己下载和管理。 |
| 消息文本 | 只保存在内存里，用于显示当前可见的消息。 |
| 翻译缓存 | 内存 LRU（默认 2000 条），退出 App 即清空，不落盘。 |
| 日志 | 只记录数量、长度、耗时、错误码；不记录原文、译文、聊天名或人名。debug 开关也一样。 |
| 设置 | UserDefaults 只保存偏好（目标语言、字号、透明度等），不含任何消息内容。 |
| 用户词表 | `~/Library/Application Support/TalkLens/glossary.json`，只包含你自己写的词条。 |
| 剪贴板 | 只有你点击"复制译文"时才写入。 |
| 截屏 | 不截屏，不录屏。 |
| KakaoTalk 数据 | 不读取、不解密 KakaoTalk 的数据目录、数据库或缓存；不使用其网络协议。 |
| 遥测 | 没有。 |

TalkLens 通过 macOS 辅助功能（Accessibility）接口读取**已经打开**的聊天窗口里**可见**的文字。辅助功能权限很强，你可以随时在 系统设置 → 隐私与安全性 → 辅助功能 里关掉它。

## English

TalkLens handles messages other people sent to you, who never agreed to share them with third parties. The design rule is: **message text never leaves this Mac's memory.**

| Item | What TalkLens does |
|---|---|
| Network | Makes no network requests at all. No URLSession, Network.framework or WebKit in the code (enforced by `scripts/guard_readonly.sh`). |
| Translation | Apple Translation framework, on-device models managed by macOS. |
| Message text | Held in memory only, for the messages currently visible. |
| Translation cache | In-memory LRU (2000 entries by default), cleared on quit, never written to disk. |
| Logs | Counts, lengths, durations and error codes only — never original text, translations, chat names or people's names (debug mode included). |
| Settings | UserDefaults stores preferences only (target language, font size, opacity…), no message content. |
| User glossary | `~/Library/Application Support/TalkLens/glossary.json`, containing only entries you wrote. |
| Clipboard | Written only when you click "copy translation". |
| Screen capture | None. |
| KakaoTalk data | Never reads or decrypts KakaoTalk's data directories, databases or caches; never uses its network protocol. |
| Telemetry | None. |

TalkLens reads the **visible** text of chat windows that are **already open**, through the macOS Accessibility API. That permission is powerful; you can revoke it any time in System Settings → Privacy & Security → Accessibility.
