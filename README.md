# TalkLens

**Unofficial, read-only translation overlay for KakaoTalk on macOS — on-device, offline, open source.**

**[中文](#中文) · [English](#english)**

---

## 中文

TalkLens 是一个 macOS 菜单栏小工具。它以**只读**方式读取你已经打开的 KakaoTalk for Mac 聊天窗口，用 macOS 自带的 **Apple 翻译**（本机、离线）翻译消息，再把译文**直接覆盖显示在每个气泡上**，效果类似浏览器里的"沉浸式翻译"。原文语言和目标语言都可以选，默认是自动检测，翻成简体中文。

> ⚠️ **非官方项目，与 Kakao Corp. 没有任何关系**，也没有得到 Kakao 的认可或支持。"KakaoTalk" 是 Kakao Corp. 的商标，这里只用来说明兼容对象。
>
> - TalkLens **只读**：不发送、不点击、不输入、不滚动，也不激活、启动或关闭 KakaoTalk。
> - 它依赖 KakaoTalk 的辅助功能（Accessibility）界面结构，**KakaoTalk 更新后可能失效**。
> - **使用者自担风险。** 软件按 MIT 许可"原样"提供，不附带任何担保。

### 安装

**方式一：一行命令（推荐）**

在「终端」里粘贴并回车：

```bash
curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash
```

这条命令会做这几件事：

1. 从 GitHub Releases 下载最新版；
2. 校验 SHA-256；
3. 安装到「应用程序」；
4. 去掉下载隔离标记（本项目没有做 Apple 公证，见下文 Gatekeeper）；
5. 打开 TalkLens。

**方式二：手动**

1. 从 [Releases](https://github.com/Amulopapa67/TalkLens/releases/latest) 下载 `TalkLens.dmg`，打开后把 TalkLens 拖进「应用程序」。
2. 第一次打开时，如果提示"无法验证开发者"：
   - 在 Finder 里**右键 → 打开**；
   - 或者到 系统设置 → 隐私与安全性，在页面底部点「仍要打开」。

**首次运行**

1. 引导窗口会带你打开 系统设置 → 隐私与安全性 → **辅助功能**，在那里打开 TalkLens 的开关。授权后马上生效，不用重启。
2. 如果还没装过翻译语言，引导窗口会弹出系统下载框，按提示下载即可（只需一次）。
3. 打开任意 KakaoTalk 聊天窗口，译文就会出现在气泡上。

> 更新版本后，如果 TalkLens 读不到 KakaoTalk，到辅助功能设置里把 TalkLens 的开关关掉再打开。原因是 ad-hoc 签名每个版本都不同，macOS 会把它当成新 App。

### 使用

- **沉浸式（默认）**：译文直接盖在每个气泡上，自己的消息是黄底，别人的是白底；滚动、拖动窗口时跟着走。
  - 想看原文时，**鼠标移到气泡上**，这一条就显示原文，旁边浮出一张卡片，里面是译文和词表注释；**按住 ⌥（Option）**，所有原文一起显示。
  - 覆盖层鼠标可以穿透，点击、选字、回复、表情回应都和平时一样。
- **多窗口**：同时打开的多个聊天窗口（群聊、私聊、开放聊天、商业账号）都会各自翻译。被别的窗口挡住的部分不画译文。
- **侧栏模式**（菜单栏 → 显示方式）：译文排成列表，贴在聊天窗口旁边。
- **不送翻译的内容**：纯表情、ㅋㅋ/ㅎㅎ 这类字母缩写（会显示注释）、链接、数字，以及已经是目标语言的消息。
- **词表**：内置韩→中的校园、实验室和俚语词表，例如 랩미팅 = 组会、휴강 = 停课；也可以在设置里编辑自己的词表。
- **设置**：原文语言（自动检测或指定）、目标语言、显示方式、字号、透明度、开机启动等。

### 系统要求

- macOS 15 或更新版本。macOS 26+ 体验最好：翻译不需要隐藏窗口，延迟更低。
- KakaoTalk for Mac（已在 26.8.0 上测试）。

### 隐私

- **TalkLens 本身零网络**：翻译全部在本机完成。只有安装脚本会联网，用来下载安装包。
- 消息文本**只在内存里**；翻译缓存是内存 LRU，退出即清空，不写任何文件。
- 日志只记录数量、耗时和错误码，**不记录消息原文或聊天名**。没有遥测。
- 详见 [PRIVACY.md](PRIVACY.md)。

### 它不会做什么

- 不碰 KakaoTalk 的网络协议（LOCO）。
- 不读取、不解密 KakaoTalk 的本地数据库或缓存。
- 不注入、不 hook、不使用私有框架。
- 不截屏（遮挡判断只读窗口的位置等元信息）。
- 不模拟键盘鼠标；只监听滚轮、鼠标移动和修饰键，用来同步覆盖层。
- 不写剪贴板（唯一例外：你在侧栏里点"复制译文"时）。

### Gatekeeper 与签名

发布版用 ad-hoc 签名，没有 Apple Developer ID 公证，所以 macOS 第一次会拦一下。安装脚本会去掉隔离标记；手动安装时用"右键 → 打开"即可。不放心的话，可以从源码自己构建（见下）。

### 从源码构建

需要 Swift 6 工具链（Xcode 16+ 或 Command Line Tools）。

```bash
swift build -c release
./scripts/build_app.sh          # 生成并签名 build/TalkLens.app
./scripts/package_release.sh    # 生成 dist/TalkLens.dmg 和 dist/TalkLens.zip（ad-hoc 签名）
./scripts/verify.sh             # 完整验收（构建、测试、只读守卫、回放、性能、打包…）
```

开发文档：[docs/architecture.md](docs/architecture.md)、[docs/ax-map.md](docs/ax-map.md)（KakaoTalk 的 AX 结构实测）、[docs/decisions.md](docs/decisions.md)。

### 已知限制

- 依赖 KakaoTalk 的界面结构，更新后可能需要适配。
- KakaoTalk 只把已加载的消息放进 AX 树。更早的历史要你在 KakaoTalk 里往上滚，加载出来后才会被翻译。
- 用键盘滚动（PageUp/方向键）时没有滚动事件，译文最多约 1 秒后才对齐。
- Apple 翻译对口语和俚语一般，词表和随时可看的原文用来弥补。

### 许可与致谢

MIT 许可，见 [LICENSE](LICENSE)。`Sources/KakaoAX/` 中部分代码改写自 [kmsg](https://github.com/channprj/kmsg)（MIT，Copyright (c) 2026 Park Hee Chan），只保留了只读部分，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

## English

TalkLens is a macOS menu bar companion that **reads** the KakaoTalk for Mac chat windows you already have open, translates messages on-device with **Apple Translation** (offline), and paints each translation **right over its message bubble** — like an "immersive translation" browser extension. Source and target languages are selectable (default: auto-detect → Simplified Chinese).

> ⚠️ **TalkLens is an unofficial project and is not affiliated with Kakao Corp.**, nor endorsed or supported by it. "KakaoTalk" is a trademark of Kakao Corp. and is used here only to describe compatibility.
>
> - TalkLens is **read-only**: it never sends, clicks, types or scrolls, and never activates, launches or quits KakaoTalk.
> - It relies on KakaoTalk's accessibility (AX) structure and **may break when KakaoTalk updates**.
> - **Use at your own risk.** The software is provided "as is" under the MIT License, without warranty of any kind.

### Install

**One line (recommended)** — paste into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash
```

What the script does:

1. downloads the latest release;
2. verifies its SHA-256;
3. installs it into /Applications;
4. removes the download quarantine flag (the app is not notarized — see Gatekeeper below);
5. opens TalkLens.

**Manual** — download `TalkLens.dmg` from [Releases](https://github.com/Amulopapa67/TalkLens/releases/latest) and drag TalkLens into Applications. On first launch, if macOS says the developer cannot be verified, **right-click → Open**, or click "Open Anyway" at the bottom of System Settings → Privacy & Security.

**First run**

1. Enable TalkLens in System Settings → Privacy & Security → **Accessibility** (the onboarding window takes you there). It takes effect immediately.
2. Download the translation languages if asked.
3. Open any KakaoTalk chat window.

After an update, toggle the Accessibility switch off and on again if TalkLens cannot read KakaoTalk (ad-hoc signatures change between builds).

### Usage

- **Immersive (default)**: translations cover each bubble and follow scrolling and window moves.
  - **Hover** a bubble to reveal its original, with a card showing the translation and glossary notes.
  - **Hold ⌥ (Option)** to reveal all originals.
  - The overlay is click-through, so clicking, selecting text, replying and reactions all work as usual.
- **Multiple windows**: every open chat window (group, 1:1, open chat, business channel) is translated; parts covered by other windows are left alone.
- **Sidebar mode** (menu bar → display mode): a docked list next to the chat window.
- **Not machine-translated**: emoji-only, jamo shorthand like ㅋㅋ/ㅎㅎ (shown with a note), links, numbers, messages already in the target language.
- **Glossary**: a built-in Korean→Chinese campus/lab/slang glossary (e.g. 랩미팅 = 组会); a user glossary is editable.
- **Settings**: source language (auto or fixed), target language, display mode, font size, opacity, launch at login.

### Requirements

- macOS 15 or later (macOS 26+ recommended).
- KakaoTalk for Mac (tested with 26.8.0).

### Privacy

- **The app makes no network requests**; translation happens entirely on device. Only the installer downloads the release.
- Message text stays **in memory only**; the translation cache is an in-memory LRU cleared on quit; nothing is written to disk.
- Logs contain only counts, durations and error codes — never message text or chat names. No telemetry.
- See [PRIVACY.md](PRIVACY.md).

### What it never does

- No KakaoTalk network protocol (LOCO).
- No reading or decrypting KakaoTalk's local databases or caches.
- No injection, hooking or private frameworks.
- No screen capture (occlusion uses window metadata only).
- No synthetic keyboard/mouse events. It only observes scroll, mouse-move and modifier-key events to keep the overlay in sync.
- No clipboard writes, except when you click "copy translation" in the sidebar.

### Gatekeeper & signing

Release builds are ad-hoc signed and not notarized (no Apple Developer ID), so macOS asks once. The installer removes the quarantine flag; for manual installs use right-click → Open. You can always build from source instead.

### Build from source

Requires a Swift 6 toolchain (Xcode 16+ or Command Line Tools).

```bash
swift build -c release
./scripts/build_app.sh          # builds and signs build/TalkLens.app
./scripts/package_release.sh    # dist/TalkLens.dmg + dist/TalkLens.zip (ad-hoc signed)
./scripts/verify.sh             # full acceptance run
```

### Known limitations

- Depends on KakaoTalk's UI structure; updates may require adjustments.
- Only messages KakaoTalk has loaded into its AX tree can be translated. To translate older history, scroll up in KakaoTalk so it loads.
- Keyboard scrolling (PageUp / arrow keys) posts no scroll events, so the overlay can take up to ~1 s to re-align.
- Apple Translation is weak on slang; the glossary and the always-available original help.

### License & credits

MIT — see [LICENSE](LICENSE). Parts of `Sources/KakaoAX/` are derived from [kmsg](https://github.com/channprj/kmsg) (MIT, Copyright (c) 2026 Park Hee Chan), reduced to its read-only subset; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
