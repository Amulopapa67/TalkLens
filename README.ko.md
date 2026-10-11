<div align="center">

<img src="assets/banner.png" alt="TalkLens — 카카오톡 몰입형 번역" width="100%">

[English](README.md) · [简体中文](README.zh-CN.md) · **한국어**

<p>
  <a href="https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.dmg"><img alt="TalkLens.dmg 다운로드" src="https://img.shields.io/badge/다운로드-TalkLens.dmg-FEE500?style=for-the-badge&logo=apple&logoColor=3C1E1E&labelColor=3C1E1E"></a>
</p>

<p>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-FEE500?logo=apple&logoColor=FEE500&labelColor=3C1E1E">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-FEE500?logo=swift&logoColor=FEE500&labelColor=3C1E1E">
  <img alt="기기 내 번역" src="https://img.shields.io/badge/번역-기기_내_오프라인-FEE500?labelColor=3C1E1E">
  <img alt="읽기 전용" src="https://img.shields.io/badge/KakaoTalk-읽기_전용-FEE500?labelColor=3C1E1E">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-FEE500?labelColor=3C1E1E"></a>
</p>

**외국인 유학생·연구자를 위한 카카오톡 번역 도우미.**<br>
TalkLens는 카카오톡 말풍선 위에 번역을 바로 겹쳐 보여 줍니다. 모든 번역은 Mac 안에서 오프라인으로 처리되며, 메시지에는 손대지 않습니다.

</div>

<br>

<p align="center">
  <img src="assets/demo.png" alt="사용 전후 비교: 카카오톡 말풍선이 그 자리에서 번역되고, 마우스를 올리면 번역과 용어 설명이 나타납니다" width="100%">
</p>

> [!IMPORTANT]
> TalkLens는 **비공식** 프로젝트이며 **Kakao Corp.와 아무런 관련이 없습니다**. Kakao의 승인이나 지원을 받지 않았습니다. "KakaoTalk"은 Kakao Corp.의 상표이며, 호환 대상을 설명하기 위해서만 사용합니다.
>
> TalkLens는 **읽기 전용**입니다. 카카오톡이 업데이트되면 **동작하지 않을 수 있습니다**. 소프트웨어는 있는 그대로 제공되며, **사용에 따른 책임은 사용자에게 있습니다**.

## ✨ 기능

| | |
|---|---|
| 🫧 **몰입형 오버레이** | 번역이 각 말풍선 위에 정확히 겹쳐집니다(내 메시지는 노란색, 상대 메시지는 흰색). 스크롤, 창 이동, 새 메시지에도 따라옵니다. |
| 👀 **원문은 언제든지** | 말풍선에 마우스를 올리면 그 메시지의 원문과 함께 번역·용어 카드가 나타납니다. **⌥ Option**을 누르고 있으면 전체 원문이 보입니다. |
| 🪟 **모든 채팅창** | 그룹 채팅, 1:1, 오픈채팅, 카카오톡 채널까지, 열려 있는 창을 동시에 번역합니다. 다른 창에 가려진 부분에는 그리지 않습니다. |
| 🌐 **다양한 언어** | 원문은 기본 한국어이며, 자동 감지나 다른 언어를 선택할 수 있습니다. 번역 대상은 중국어(간체/번체)·영어·일본어 등입니다. 앱 언어는 中文 / 繁體 / English / 한국어 / 日本語 중에서 고를 수 있습니다. |
| 📚 **캠퍼스·연구실 용어집** | 랩미팅, 휴강, 보강, ㅋㅋ 등을 작은 태그로 설명합니다. 나만의 용어도 추가할 수 있습니다. |
| 🔒 **개인정보 우선** | Apple 번역이 기기 안에서 실행됩니다. 네트워크 없음, 메시지 원문 기록 없음, 디스크 저장 없음. |
| 🖱️ **방해하지 않음** | 오버레이는 클릭이 통과되므로 선택·답장·공감·입력을 평소처럼 할 수 있습니다. |

## 🚀 설치

**방법 A: 앱 다운로드** (추천)

1. **[TalkLens.dmg](https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.dmg)**를 받아 열고, **TalkLens**를 **Applications**(응용 프로그램)로 끌어다 놓으세요.
2. 처음 열 때는 **TalkLens를 우클릭 → 열기**를 선택하세요. 오픈소스지만 Apple 공증을 받지 않아 macOS가 한 번 확인합니다.

**방법 B: 터미널 한 줄**

```bash
curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash
```

최신 버전을 내려받고, SHA-256을 확인하고, 응용 프로그램에 설치하고, 다운로드 격리 표시를 지운 뒤 TalkLens를 실행합니다.

**그다음**

1. 안내 창이 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**을 엽니다. **TalkLens**를 켜면 바로 동작합니다.
2. 안내가 나오면 번역 언어를 내려받으세요(최초 1회, macOS가 처리).
3. 카카오톡 채팅창을 열면 끝입니다 🎉

**방법 C: AI 어시스턴트에게 맡기기**

저장소에 에이전트 스킬 [`skills/talklens-installer`](skills/talklens-installer/SKILL.md)가 들어 있습니다. Claude Code, Codex 등 `SKILL.md`를 지원하는 어시스턴트에서 쓸 수 있습니다.

- Mac 상태를 확인하고;
- 최신 버전을 내려받아 검증하고;
- 설치한 뒤;
- 손쉬운 사용 권한 설정을 안내합니다.

무엇이든 바꾸기 전에 먼저 묻고, 채팅에는 손대지 않습니다.

<details>
<summary><b>요구 사항</b></summary>

- macOS 15 Sequoia 이상(지연이 가장 짧은 macOS 26 이상 권장)
- KakaoTalk for Mac(26.8.0에서 테스트)
- Apple Silicon / Intel

</details>

## 🧭 사용법

- **메뉴 막대 아이콘**: 일시정지/재개, 표시 방식(몰입형/사이드바), 언어, 설정, 안내, 정보.
- **몰입형**(기본): 말풍선 위에 번역 표시. 마우스를 올리거나 ⌥를 누르면 원문이 보입니다.
- **사이드바 모드**: 채팅창 옆에 번역 목록을 붙여서 나란히 읽습니다.
- **번역하지 않는 내용**: 이모지만 있는 메시지, ㅋㅋ/ㅎㅎ 같은 줄임말(대신 설명 표시), 링크, 숫자, 이미 대상 언어로 된 메시지.
- **설정**: 원문/대상 언어, 앱 언어, 표시 방식, 글자 크기, 투명도, 용어집, 로그인 시 실행.

## 🔒 개인정보

TalkLens는 macOS 손쉬운 사용 API로 **이미 열려 있는** 채팅창의 텍스트를 읽고, **기기 안에서** 번역합니다.

- **앱은 네트워크를 전혀 사용하지 않습니다**(CI의 검사 스크립트로 확인). 선택 사항인 설치 스크립트만 설치 파일을 내려받습니다.
- 메시지 텍스트는 **메모리에만** 있으며, 종료하면 번역 캐시가 지워집니다.
- 로그에는 개수와 소요 시간만 남고, 메시지 원문이나 채팅방 이름은 기록하지 않습니다. 원격 측정 없음.
- 전송·클릭·입력·스크롤을 하지 않습니다. 카카오톡의 네트워크 프로토콜, 데이터베이스, 캐시에 접근하지 않습니다. 코드 주입, 비공개 프레임워크, 화면 캡처도 사용하지 않습니다.

자세한 내용: [PRIVACY.md](PRIVACY.md)

## ❓ 자주 묻는 질문

<details>
<summary><b>"개발자를 확인할 수 없습니다"라고 나와요</b></summary>

배포 빌드는 ad-hoc 서명이며 공증을 받지 않았습니다(유료 Apple Developer ID 필요). 이렇게 해결하세요.

- 앱을 우클릭 → **열기**;
- 또는 시스템 설정 → 개인정보 보호 및 보안 맨 아래에서 **그래도 열기**.

한 줄 설치 스크립트는 이 과정을 자동으로 처리합니다. 소스에서 직접 빌드해도 됩니다.
</details>

<details>
<summary><b>업데이트 후 번역이 안 돼요</b></summary>

ad-hoc 서명은 빌드마다 달라서 macOS가 새 앱으로 인식합니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 TalkLens를 껐다가 다시 켜 주세요.
</details>

<details>
<summary><b>예전 메시지는 번역되지 않아요</b></summary>

TalkLens는 카카오톡이 불러온 메시지만 볼 수 있습니다. 카카오톡에서 위로 스크롤해 예전 대화를 불러오면 함께 번역됩니다.
</details>

<details>
<summary><b>보내는 메시지도 번역해 주나요?</b></summary>

아니요. TalkLens는 철저히 읽기 전용이며 카카오톡에 아무것도 입력하지 않습니다.
</details>

## 🛠️ 소스에서 빌드

Swift 6 툴체인(Xcode 16 이상 또는 Command Line Tools)이 필요합니다.

```bash
swift build -c release
./scripts/build_app.sh          # build/TalkLens.app
./scripts/package_release.sh    # dist/TalkLens.dmg + dist/TalkLens.zip
swift test
```

## 📄 라이선스

MIT. [LICENSE](LICENSE)를 참고하세요. `Sources/KakaoAX/`의 일부 코드는 [kmsg](https://github.com/channprj/kmsg)(MIT, © 2026 Park Hee Chan)에서 읽기 전용 부분만 가져와 수정했습니다. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 참고.

<div align="center"><sub>한국어 채팅을 읽으려 애쓰는 모든 분을 위해 · Kakao와 무관</sub></div>
