<div align="center">

<img src="assets/banner.png" alt="TalkLens — KakaoTalk 沉浸式翻译" width="100%">

[English](README.md) · **简体中文** · [한국어](README.ko.md)

<p>
  <a href="https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.dmg"><img alt="下载 TalkLens.dmg" src="https://img.shields.io/badge/下载-TalkLens.dmg-FEE500?style=for-the-badge&logo=apple&logoColor=3C1E1E&labelColor=3C1E1E"></a>
</p>

<p>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-FEE500?logo=apple&logoColor=FEE500&labelColor=3C1E1E">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FEE500?logo=swift&logoColor=FEE500&labelColor=3C1E1E">
  <img alt="本机翻译" src="https://img.shields.io/badge/翻译-本机离线-FEE500?labelColor=3C1E1E">
  <img alt="只读" src="https://img.shields.io/badge/KakaoTalk-只读-FEE500?labelColor=3C1E1E">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-FEE500?labelColor=3C1E1E"></a>
</p>

**看韩语群聊，像看母语一样。**<br>
TalkLens 把译文直接贴在 KakaoTalk 的每个气泡上。全部在你的 Mac 上离线完成，不碰任何一条消息。

</div>

<br>

<p align="center">
  <img src="assets/demo.png" alt="使用前后对比：KakaoTalk 气泡被原地翻译，悬停时显示译文和词表注释" width="100%">
</p>

> [!IMPORTANT]
> TalkLens 是**非官方**项目，**与 Kakao Corp. 没有任何关系**，也没有得到它的认可或支持。"KakaoTalk" 是 Kakao Corp. 的商标，这里只用来说明兼容对象。
>
> TalkLens **只读**。KakaoTalk 更新后它**可能失效**。软件按原样提供，**使用者自担风险**。

## ✨ 功能

| | |
|---|---|
| 🫧 **沉浸式覆盖** | 译文正好盖在每个气泡上（自己的黄色、别人的白色），滚动、拖动窗口、来新消息时都跟着走。 |
| 👀 **随时看原文** | 鼠标移到气泡上：这一条显示原文，旁边出现译文 + 词表卡片。按住 **⌥ Option**：所有原文一起显示。 |
| 🪟 **所有聊天窗口** | 群聊、私聊、开放聊天、商业账号，打开的窗口同时翻译。被别的窗口挡住的部分不会乱画。 |
| 🌐 **任意语言对** | 原文默认韩语，也可以选智能识别或指定语言。目标支持简体/繁体中文、英语、日语等。界面语言可选：中文 / 繁體 / English / 한국어 / 日本語。 |
| 📚 **校园和实验室词表** | 랩미팅 = 组会、휴강 = 停课、ㅋㅋ = 哈哈……以小标签显示，也可以加自己的词条。 |
| 🔒 **隐私优先** | Apple 翻译在本机运行。不联网，不记录消息原文，不写任何文件。 |
| 🖱️ **不挡操作** | 覆盖层鼠标可以穿透，选字、回复、表情回应、打字都和平时一样。 |

## 🚀 安装

**方式一：下载 App**（推荐）

1. 下载 **[TalkLens.dmg](https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.dmg)**，打开后把 **TalkLens** 拖到 **Applications**（应用程序）。
2. 第一次打开时，**右键 TalkLens → 打开**。本项目开源，但没有经过 Apple 公证，所以 macOS 会问一次。

**方式二：终端一行命令**

```bash
curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash
```

这条命令会下载最新版、校验 SHA-256、装进「应用程序」、去掉下载隔离标记，然后打开 TalkLens。

**接下来**

1. 引导窗口会打开 **系统设置 → 隐私与安全性 → 辅助功能**，在那里打开 **TalkLens** 的开关，马上生效。
2. 如有提示，下载翻译语言（只需一次，由 macOS 完成）。
3. 打开任意 KakaoTalk 聊天窗口，就可以用了 🎉

<details>
<summary><b>系统要求</b></summary>

- macOS 15 Sequoia 或更新版本（推荐 macOS 26+，延迟更低）
- KakaoTalk for Mac（已在 26.8.0 上测试）
- Apple Silicon 或 Intel 都可以

</details>

## 🧭 使用

- **菜单栏图标**：暂停/继续、显示方式（沉浸式 / 侧栏）、语言、设置、引导、关于。
- **沉浸式**（默认）：译文盖在气泡上；悬停或按住 ⌥ 看原文。
- **侧栏模式**：译文排成列表贴在聊天窗口旁边，适合左右对照着看。
- **不送翻译的内容**：纯表情、ㅋㅋ/ㅎㅎ 这类缩写（改为显示注释）、链接、数字、已经是目标语言的消息。
- **设置**：原文/目标语言、界面语言、显示方式、字号、透明度、词表、开机启动。

## 🔒 隐私

TalkLens 通过 macOS 辅助功能接口，读取**已经打开**的聊天窗口里的文字，然后**在本机**翻译。

- **App 本身不联网**（CI 里有守卫脚本检查）。只有可选的安装脚本会下载安装包。
- 消息文本**只在内存里**，退出后翻译缓存清空。
- 日志只记数量和耗时，不记录消息原文或聊天名。没有遥测。
- 不发送、不点击、不输入、不滚动；不碰 KakaoTalk 的网络协议、数据库或缓存；不注入、不用私有框架、不截屏。

详见 [PRIVACY.md](PRIVACY.md)。

## ❓ 常见问题

<details>
<summary><b>提示"无法验证开发者"</b></summary>

发布版用 ad-hoc 签名，没有公证（公证需要付费的 Apple Developer ID）。处理方法：

- 右键 App → **打开**；
- 或者到 系统设置 → 隐私与安全性，在页面底部点 **仍要打开**。

一行安装命令会自动处理这一步。你也可以从源码自己构建。
</details>

<details>
<summary><b>更新后不翻译了</b></summary>

ad-hoc 签名每次构建都不同，macOS 会把新版当成新 App。到 系统设置 → 隐私与安全性 → 辅助功能，把 TalkLens 的开关关掉再打开。
</details>

<details>
<summary><b>更早的消息没有翻译</b></summary>

TalkLens 只能看到 KakaoTalk 已经加载的消息。在 KakaoTalk 里往上滚，旧消息加载出来后也会被翻译。
</details>

<details>
<summary><b>能翻译我要发出去的消息吗？</b></summary>

不能。TalkLens 严格只读，不会往 KakaoTalk 里输入任何东西。
</details>

## 🛠️ 从源码构建

需要 Swift 6 工具链（Xcode 16+ 或 Command Line Tools）。

```bash
swift build -c release
./scripts/build_app.sh          # build/TalkLens.app
./scripts/package_release.sh    # dist/TalkLens.dmg + dist/TalkLens.zip
swift test                      # 单元、回放、翻译调度测试
```

架构：[docs/architecture.md](docs/architecture.md) · KakaoTalk AX 结构实测：[docs/ax-map.md](docs/ax-map.md) · 设计决策：[docs/decisions.md](docs/decisions.md) · 性能：[docs/PERF.md](docs/PERF.md)

## 📄 许可与致谢

MIT 许可，见 [LICENSE](LICENSE)。`Sources/KakaoAX/` 的部分代码改写自 [kmsg](https://github.com/channprj/kmsg)（MIT，© 2026 Park Hee Chan），只保留了只读部分，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<div align="center"><sub>为每一个在学看韩语聊天的人而做 · 与 Kakao 无关</sub></div>
