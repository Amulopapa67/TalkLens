// SPDX-License-Identifier: MIT
// Typed UI string table (D-024). Every key has a translation for every UILanguage; the exhaustive switch in
// `entry(_:)` plus the five-field initializer make a missing translation a compile error. Placeholders are
// positional ("{0}", "{1}", …) so languages can reorder arguments. No chat content ever goes through here.

import Foundation

/// Every user-visible string of the app.
public enum UIKey: String, CaseIterable, Sendable {
    // Menu bar menu
    case menuPause, menuResume, menuHideOverlay, menuShowOverlay, menuHideSidebar, menuShowSidebar, menuPinned
    case menuSourceLanguage, menuTargetLanguage, menuUILanguage, menuDownloadMissing
    case menuSettings, menuOnboarding, menuAbout, menuQuit
    // Display modes and sidebar edges
    case displayMode, displayModeInline, displayModeSidebar
    case edgeRight, edgeLeft, edgeInside
    // Status line and states
    case statusLine, statePaused, stateStarting, stateNoPermission, stateKakaoNotRunning, stateNoChatWindow
    case stateTranscriptNotFound, stateFollowingOne, stateFollowingMany, stateCounts, stateMissingPairs
    // Window titles
    case windowOnboarding, windowSettings, windowDownload
    // Settings
    case sectionGeneral, uiLanguage, uiLanguageSystem, uiLanguageSystemResolved, uiLanguageFooter
    case sectionTranslation, sourceLanguage, targetLanguage, languageAuto, showOriginalByDefault, translationFooter
    case displayModeFooter, panelEdge, panelWidth, fontSize, backgroundOpacity, pinnedLong, showTranslations
    case sectionGlossary, glossaryEnabled, glossaryEntries, glossaryCounts, glossaryEdit, glossaryReload
    case glossaryFooter, glossaryErrorBundled, glossaryErrorUser, glossaryErrorCreate
    case sectionSystem, launchAtLogin, status, openLoginItems
    case loginEnabled, loginNotRegistered, loginRequiresApproval, loginNotFound, unknownState
    case sectionPrivacy, privacyFooter
    case sameLanguage, pairStatus, download, installedFor, checking, needsDownload, nothing
    case engineReady, engineUnsupported
    // Onboarding
    case onboardingWelcome, onboardingIntro, onboardingAXTitle, onboardingAXGranted, onboardingAXNeeded
    case onboardingOpenSystemSettings, onboardingLanguageTitle, downloadLanguages, onboardingRecheck
    case onboardingKakaoRunning, onboardingKakaoRunningVersion, onboardingKakaoNotRunning, onboardingDisclaimer
    case onboardingDone, onboardingLater, engineInstalledSentence, engineNeedsDownloadSentence, engineUnavailable
    case engineHostRequired, engineUnknownSentence, autoDetected
    // About
    case aboutVersion, aboutDescription, aboutDiagnostics, aboutMetric, aboutFollow, aboutNewToTranslation
    case aboutRead, aboutIngest, aboutBudget, aboutCounters
    // Sidebar and overlay
    case bannerMissingPairs, languagesNotInstalled, translationUnavailable, guide, headerCounts, headerFailed
    case settings, openGuide, resumeTranslation, emptyNoChatWindow, emptyStarting, emptyNoMessages
    case emptyNoPermissionDetail, emptyNoChatWindowDetail, emptyTranscriptNotFoundDetail, newMessages
    case copyTranslation, clickToHideOriginal, clickToShowOriginal, hideOriginal, showOriginal, me
    case attachImages, attachLinks, attachFiles, glossaryBadge
    // Translation failures
    case failNotInstalledPair, failUnsupportedPair, failUnsupported, failGeneric
    // Language download prompt
    case downloadTitle, downloadBody, downloadTryAgain, downloadNotYet, downloadWaiting, downloadStillNot
    case downloadUnsupported, downloadFooter
}

/// One key's text in every UI language.
public struct UIStringSet: Sendable, Equatable {
    public let zhHans: String
    public let zhHant: String
    public let en: String
    public let ko: String
    public let ja: String

    public subscript(_ language: UILanguage) -> String {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }
}

public enum UIStrings {
    /// Localized text for `key`, with "{n}" replaced by `args[n]`.
    public static func text(_ key: UIKey, _ language: UILanguage, _ args: any CustomStringConvertible...) -> String {
        text(key, language, arguments: args)
    }

    public static func text(_ key: UIKey, _ language: UILanguage,
                            arguments: [any CustomStringConvertible]) -> String {
        format(template(key, language), arguments.map(\.description))
    }

    /// The raw template (placeholders not substituted).
    public static func template(_ key: UIKey, _ language: UILanguage) -> String {
        entry(key)[language]
    }

    static func format(_ template: String, _ args: [String]) -> String {
        guard !args.isEmpty else { return template }
        var out = template
        for (i, value) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: value)
        }
        return out
    }

    /// Placeholder indices used by a template ("{0} 和 {1}" → [0, 1]).
    public static func placeholders(in template: String) -> [Int] {
        var result: [Int] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else { break }
            if let n = Int(after[..<close]) { result.append(n) }
            rest = after[after.index(after: close)...]
        }
        return result.sorted()
    }

    // MARK: - Language names

    /// Name of a translation language (catalog id) in the UI language: "韩语", "Korean", "한국어", …
    public static func languageName(_ id: String, _ language: UILanguage) -> String {
        let c = LanguageCatalog.canonicalID(id) ?? id
        guard let set = languageNames[c] else { return LanguageCatalog.displayName(id) }
        return set[language]
    }

    /// The language's name in itself (Chinese variants as "简体中文" / "繁體中文").
    public static func nativeLanguageName(_ id: String) -> String {
        let c = LanguageCatalog.canonicalID(id) ?? id
        if c == "zh-Hans" { return UILanguage.zhHans.nativeName }
        if c == "zh-Hant" { return UILanguage.zhHant.nativeName }
        return LanguageCatalog.displayName(c)
    }

    /// Picker label: native name plus the UI-language name in parentheses when that helps
    /// ("한국어 (Korean)", "日本語（日语）"); just the native name when both read the same.
    public static func languageOptionLabel(_ id: String, _ language: UILanguage) -> String {
        if id == LanguageCatalog.autoID { return text(.languageAuto, language) }
        let native = nativeLanguageName(id)
        let local = languageName(id, language)
        if native == local || (language.isChinese && LanguageCatalog.isChinese(id)) { return native }
        return native + parenthesized(local, language)
    }

    /// UI language picker label, e.g. "한국어 (Korean)" in an English UI.
    public static func uiLanguageOptionLabel(_ option: UILanguage, _ language: UILanguage) -> String {
        languageOptionLabel(option.rawValue, language)
    }

    /// "日语→简体中文" in the UI language (auto shows as the auto-detect label).
    public static func pairName(_ pair: LanguagePair, _ language: UILanguage) -> String {
        "\(languageName(pair.source, language))→\(languageName(pair.target, language))"
    }

    /// "（x）" for Chinese / Japanese, " (x)" for English and Korean.
    public static func parenthesized(_ value: String, _ language: UILanguage) -> String {
        switch language {
        case .zhHans, .zhHant, .ja: return "（\(value)）"
        case .en, .ko: return " (\(value))"
        }
    }

    /// Joins a list with the language's enumeration comma.
    public static func list(_ items: [String], _ language: UILanguage) -> String {
        switch language {
        case .zhHans, .zhHant, .ja: return items.joined(separator: "、")
        case .en, .ko: return items.joined(separator: ", ")
        }
    }

    static let languageNames: [String: UIStringSet] = [
        "ko": s("韩语", "韓文", "Korean", "한국어", "韓国語"),
        "en": s("英语", "英文", "English", "영어", "英語"),
        "ja": s("日语", "日文", "Japanese", "일본어", "日本語"),
        "zh-Hans": s("简体中文", "簡體中文", "Chinese (Simplified)", "중국어(간체)", "中国語（簡体字）"),
        "zh-Hant": s("繁体中文", "繁體中文", "Chinese (Traditional)", "중국어(번체)", "中国語（繁体字）"),
        "es": s("西班牙语", "西班牙文", "Spanish", "스페인어", "スペイン語"),
        "fr": s("法语", "法文", "French", "프랑스어", "フランス語"),
        "de": s("德语", "德文", "German", "독일어", "ドイツ語"),
        "ru": s("俄语", "俄文", "Russian", "러시아어", "ロシア語"),
        "vi": s("越南语", "越南文", "Vietnamese", "베트남어", "ベトナム語"),
        "th": s("泰语", "泰文", "Thai", "태국어", "タイ語"),
        "id": s("印尼语", "印尼文", "Indonesian", "인도네시아어", "インドネシア語"),
    ]

    private static func s(_ zhHans: String, _ zhHant: String, _ en: String, _ ko: String, _ ja: String) -> UIStringSet {
        UIStringSet(zhHans: zhHans, zhHant: zhHant, en: en, ko: ko, ja: ja)
    }

    // MARK: - Table

    public static func entry(_ key: UIKey) -> UIStringSet {
        switch key {
        // Menu bar menu
        case .menuPause: return s("暂停翻译", "暫停翻譯", "Pause Translation", "번역 일시 정지", "翻訳を一時停止")
        case .menuResume: return s("启用翻译", "啟用翻譯", "Resume Translation", "번역 다시 시작", "翻訳を再開")
        case .menuHideOverlay:
            return s("隐藏译文覆盖", "隱藏譯文覆蓋", "Hide Translation Overlay", "번역 오버레이 숨기기", "翻訳オーバーレイを隠す")
        case .menuShowOverlay:
            return s("显示译文覆盖", "顯示譯文覆蓋", "Show Translation Overlay", "번역 오버레이 표시", "翻訳オーバーレイを表示")
        case .menuHideSidebar: return s("隐藏侧栏", "隱藏側欄", "Hide Sidebar", "사이드바 숨기기", "サイドバーを隠す")
        case .menuShowSidebar: return s("显示侧栏", "顯示側欄", "Show Sidebar", "사이드바 표시", "サイドバーを表示")
        case .menuPinned: return s("常驻显示", "常駐顯示", "Keep Visible", "항상 표시", "常に表示")
        case .menuSourceLanguage: return s("原文语言：{0}", "原文語言：{0}", "Translate From: {0}", "원문 언어: {0}", "翻訳元: {0}")
        case .menuTargetLanguage: return s("目标语言：{0}", "目標語言：{0}", "Translate To: {0}", "번역 언어: {0}", "翻訳先: {0}")
        case .menuUILanguage: return s("界面语言：{0}", "介面語言：{0}", "App Language: {0}", "앱 언어: {0}", "表示言語: {0}")
        case .menuDownloadMissing:
            return s("下载缺少的翻译语言", "下載缺少的翻譯語言", "Download Missing Languages", "누락된 번역 언어 다운로드",
                     "不足している翻訳言語をダウンロード")
        case .menuSettings: return s("设置…", "設定…", "Settings…", "설정…", "設定…")
        case .menuOnboarding:
            return s("权限与语言引导…", "權限與語言引導…", "Permissions & Languages Guide…", "권한 및 언어 안내…",
                     "権限と言語のガイド…")
        case .menuAbout: return s("关于 TalkLens", "關於 TalkLens", "About TalkLens", "TalkLens 정보", "TalkLens について")
        case .menuQuit: return s("退出 TalkLens", "結束 TalkLens", "Quit TalkLens", "TalkLens 종료", "TalkLens を終了")

        // Display modes and sidebar edges
        case .displayMode: return s("显示方式", "顯示方式", "Display Mode", "표시 방식", "表示方法")
        case .displayModeInline:
            return s("沉浸式（覆盖在气泡上）", "沉浸式（覆蓋在氣泡上）", "Immersive (over chat bubbles)",
                     "몰입형(말풍선 위에 표시)", "没入型（吹き出しの上に表示）")
        case .displayModeSidebar: return s("侧栏", "側欄", "Sidebar", "사이드바", "サイドバー")
        case .edgeRight: return s("右侧外贴", "右側外貼", "Outside, right", "오른쪽 바깥", "右側の外")
        case .edgeLeft: return s("左侧外贴", "左側外貼", "Outside, left", "왼쪽 바깥", "左側の外")
        case .edgeInside:
            return s("内嵌（避让输入框）", "內嵌（避開輸入框）", "Inside (above the input field)", "안쪽(입력창 피해서)",
                     "内側（入力欄を避ける）")

        // Status line and states
        case .statusLine: return s("状态：{0}", "狀態：{0}", "Status: {0}", "상태: {0}", "状態: {0}")
        case .statePaused: return s("已暂停", "已暫停", "Paused", "일시 정지됨", "一時停止中")
        case .stateStarting: return s("启动中", "啟動中", "Starting", "시작하는 중", "起動中")
        case .stateNoPermission:
            return s("需要辅助功能权限", "需要輔助使用權限", "Accessibility permission needed", "손쉬운 사용 권한 필요",
                     "アクセシビリティの許可が必要")
        case .stateKakaoNotRunning:
            return s("KakaoTalk 未运行", "KakaoTalk 未執行", "KakaoTalk is not running", "카카오톡이 실행 중이 아님",
                     "KakaoTalk が起動していません")
        case .stateNoChatWindow:
            return s("没有打开的聊天窗口", "沒有開啟的聊天視窗", "No open chat window", "열린 채팅창 없음",
                     "開いているチャットウインドウなし")
        case .stateTranscriptNotFound:
            return s("未找到聊天记录区域", "找不到聊天記錄區域", "Chat transcript not found", "대화 내용 영역을 찾지 못함",
                     "トーク履歴の領域が見つかりません")
        case .stateFollowingOne: return s("跟随中", "跟隨中", "Following", "따라가는 중", "追従中")
        case .stateFollowingMany:
            return s("跟随 {0} 个窗口 · 当前", "跟隨 {0} 個視窗 · 目前", "Following {0} windows · current",
                     "창 {0}개 따라가는 중 · 현재", "{0} 個のウインドウを追従中 · 現在")
        case .stateCounts:
            return s("{0} 条 · 已译 {1}", "{0} 則 · 已譯 {1}", "Messages {0} · Translated {1}", "메시지 {0} · 번역됨 {1}",
                     "{0} 件 · 翻訳済み {1}")
        case .stateMissingPairs:
            return s("缺 {0} 个语言对", "缺 {0} 個語言組合", "Missing language pairs: {0}", "없는 언어 쌍 {0}개",
                     "未導入の言語ペア {0} 件")

        // Window titles
        case .windowOnboarding:
            return s("TalkLens 引导", "TalkLens 引導", "TalkLens Setup", "TalkLens 시작하기", "TalkLens セットアップ")
        case .windowSettings: return s("TalkLens 设置", "TalkLens 設定", "TalkLens Settings", "TalkLens 설정", "TalkLens 設定")
        case .windowDownload:
            return s("下载翻译语言", "下載翻譯語言", "Download Translation Languages", "번역 언어 다운로드",
                     "翻訳言語をダウンロード")

        // Settings
        case .sectionGeneral: return s("通用", "一般", "General", "일반", "一般")
        case .uiLanguage: return s("界面语言", "介面語言", "App Language", "앱 언어", "表示言語")
        case .uiLanguageSystem: return s("跟随系统", "跟隨系統", "Follow System", "시스템 설정 따르기", "システムに合わせる")
        case .uiLanguageSystemResolved:
            return s("跟随系统（{0}）", "跟隨系統（{0}）", "Follow System ({0})", "시스템 설정 따르기 ({0})",
                     "システムに合わせる（{0}）")
        case .uiLanguageFooter:
            return s("切换后立即生效，无需重启。", "切換後立即生效，無需重新啟動。", "Changes apply immediately; no restart needed.",
                     "변경 사항은 바로 적용되며 다시 시작할 필요가 없습니다.", "変更はすぐに反映され、再起動は不要です。")
        case .sectionTranslation: return s("翻译", "翻譯", "Translation", "번역", "翻訳")
        case .sourceLanguage: return s("原文语言", "原文語言", "Source Language", "원문 언어", "翻訳元の言語")
        case .targetLanguage: return s("目标语言", "目標語言", "Target Language", "번역 언어", "翻訳先の言語")
        case .languageAuto:
            return s("智能识别（自动检测）", "智慧辨識（自動偵測）", "Smart (auto-detect)", "스마트 인식 (자동 감지)",
                     "スマート判定（自動検出）")
        case .showOriginalByDefault:
            return s("默认显示原文", "預設顯示原文", "Show originals by default", "기본으로 원문 표시", "原文を常に表示")
        case .translationFooter:
            return s("默认原文语言为韩语。智能识别会逐条判断语言，已经是目标语言的消息不翻译；词表注释只用于韩语消息、中文译文。翻译完全在本机进行（Apple 翻译），不联网。",
                     "預設原文語言為韓文。智慧辨識會逐則判斷語言，已經是目標語言的訊息不翻譯；詞彙表註解只用於韓文訊息、中文譯文。翻譯完全在本機進行（Apple 翻譯），不連網。",
                     "Korean is the default source language. Smart detection checks each message, and messages already in the target language are left as they are. Glossary notes apply only to Korean messages translated into Chinese. Everything is translated on this Mac with Apple Translation, offline.",
                     "기본 원문 언어는 한국어입니다. 스마트 인식은 메시지마다 언어를 판단하며, 이미 번역 언어로 된 메시지는 번역하지 않습니다. 용어집 주석은 한국어 메시지를 중국어로 번역할 때만 표시됩니다. 번역은 모두 이 Mac에서 Apple 번역으로 처리되며 인터넷을 사용하지 않습니다.",
                     "翻訳元の既定は韓国語です。スマート判定ではメッセージごとに言語を判定し、すでに翻訳先の言語で書かれたメッセージは翻訳しません。用語集の注釈は、韓国語のメッセージを中国語に訳す場合にだけ表示されます。翻訳はすべてこの Mac 上の Apple 翻訳で行い、ネットワークは使いません。")
        case .displayModeFooter:
            return s("沉浸式：译文直接盖在 KakaoTalk 的气泡上，滚动时跟随；按住 ⌥ 显示原文，鼠标悬停在气泡上可看原文和词表注释。窗口不拦截点击。",
                     "沉浸式：譯文直接蓋在 KakaoTalk 的氣泡上，捲動時跟隨；按住 ⌥ 顯示原文，滑鼠停在氣泡上可看原文和詞彙表註解。視窗不會攔截點按。",
                     "Immersive: translations are drawn right over KakaoTalk's bubbles and follow scrolling. Hold ⌥ to see the originals; hover over a bubble to see its original and glossary notes. Clicks pass through.",
                     "몰입형: 번역문이 카카오톡 말풍선 위에 바로 표시되고 스크롤을 따라갑니다. ⌥ 키를 누르고 있으면 원문이 보이고, 말풍선 위에 마우스를 올리면 원문과 용어집 주석을 볼 수 있습니다. 클릭은 그대로 카카오톡에 전달됩니다.",
                     "没入型: 訳文を KakaoTalk の吹き出しの上に直接重ね、スクロールにも追従します。⌥ キーを押している間は原文を表示し、吹き出しにポインタを合わせると原文と用語集の注釈を確認できます。クリックはそのまま下のウインドウに届きます。")
        case .panelEdge: return s("贴靠位置", "貼靠位置", "Position", "붙는 위치", "配置")
        case .panelWidth: return s("侧栏宽度", "側欄寬度", "Sidebar Width", "사이드바 너비", "サイドバーの幅")
        case .fontSize: return s("字号", "字級", "Font Size", "글자 크기", "文字サイズ")
        case .backgroundOpacity: return s("背景不透明度", "背景不透明度", "Background Opacity", "배경 불투명도", "背景の不透明度")
        case .pinnedLong:
            return s("常驻显示（KakaoTalk 不在前台时也显示）", "常駐顯示（KakaoTalk 不在前景時也顯示）",
                     "Keep visible (even when KakaoTalk is in the background)", "항상 표시 (카카오톡이 뒤에 있을 때도)",
                     "常に表示（KakaoTalk が背面にあっても）")
        case .showTranslations:
            return s("显示译文（侧栏或沉浸式覆盖）", "顯示譯文（側欄或沉浸式覆蓋）", "Show translations (sidebar or overlay)",
                     "번역 표시 (사이드바 또는 오버레이)", "訳文を表示（サイドバーまたはオーバーレイ）")
        case .sectionGlossary: return s("词表", "詞彙表", "Glossary", "용어집", "用語集")
        case .glossaryEnabled:
            return s("启用词表注释与展开", "啟用詞彙表註解與展開", "Enable glossary notes and expansion",
                     "용어집 주석 및 확장 사용", "用語集の注釈と展開を有効にする")
        case .glossaryEntries: return s("条目", "條目", "Entries", "항목", "項目")
        case .glossaryCounts:
            return s("内置 {0} · 用户 {1}", "內建 {0} · 使用者 {1}", "Built-in {0} · User {1}", "기본 {0} · 사용자 {1}",
                     "内蔵 {0} · ユーザ {1}")
        case .glossaryEdit:
            return s("编辑用户词表…", "編輯使用者詞彙表…", "Edit User Glossary…", "사용자 용어집 편집…", "ユーザ用語集を編集…")
        case .glossaryReload:
            return s("重新加载词表", "重新載入詞彙表", "Reload Glossary", "용어집 다시 불러오기", "用語集を再読み込み")
        case .glossaryFooter:
            return s("用户词表位于 {0}，同名条目覆盖内置条目。", "使用者詞彙表位於 {0}，同名條目會覆蓋內建條目。",
                     "The user glossary is at {0}; its entries override built-in entries for the same term.",
                     "사용자 용어집 위치: {0}. 같은 단어의 항목은 기본 항목보다 우선합니다.",
                     "ユーザ用語集は {0} にあります。同じ語の項目は内蔵の項目より優先されます。")
        case .glossaryErrorBundled:
            return s("内置词表无法解析", "內建詞彙表無法解析", "The built-in glossary could not be read",
                     "기본 용어집을 읽을 수 없습니다", "内蔵の用語集を読み込めません")
        case .glossaryErrorUser:
            return s("用户词表 JSON 格式有误（已忽略）", "使用者詞彙表 JSON 格式有誤（已略過）",
                     "The user glossary is not valid JSON (ignored)", "사용자 용어집의 JSON 형식이 잘못되어 무시했습니다",
                     "ユーザ用語集の JSON 形式が正しくありません（無視しました）")
        case .glossaryErrorCreate:
            return s("无法创建用户词表文件", "無法建立使用者詞彙表檔案", "Could not create the user glossary file",
                     "사용자 용어집 파일을 만들 수 없습니다", "ユーザ用語集ファイルを作成できません")
        case .sectionSystem: return s("系统", "系統", "System", "시스템", "システム")
        case .launchAtLogin:
            return s("登录时启动 TalkLens", "登入時啟動 TalkLens", "Launch TalkLens at login", "로그인 시 TalkLens 실행",
                     "ログイン時に TalkLens を起動")
        case .status: return s("状态", "狀態", "Status", "상태", "状態")
        case .openLoginItems:
            return s("打开登录项设置…", "打開登入項目設定…", "Open Login Items Settings…", "로그인 항목 설정 열기…",
                     "ログイン項目の設定を開く…")
        case .loginEnabled: return s("已启用", "已啟用", "On", "켜짐", "オン")
        case .loginNotRegistered: return s("未启用", "未啟用", "Off", "꺼짐", "オフ")
        case .loginRequiresApproval:
            return s("需要在 系统设置 → 通用 → 登录项 中批准", "需要在「系統設定」→「一般」→「登入項目」中允許",
                     "Needs approval in System Settings → General → Login Items",
                     "시스템 설정 → 일반 → 로그인 항목에서 허용해야 합니다", "システム設定 → 一般 → ログイン項目 で許可が必要です")
        case .loginNotFound:
            return s("未找到（请从 .app 运行）", "找不到（請從 .app 執行）", "Not found (run TalkLens from its .app)",
                     "찾을 수 없음 (.app에서 실행하세요)", "見つかりません（.app から起動してください）")
        case .unknownState: return s("未知状态", "未知狀態", "Unknown", "알 수 없음", "不明")
        case .sectionPrivacy: return s("隐私", "隱私", "Privacy", "개인정보 보호", "プライバシー")
        case .privacyFooter:
            return s("TalkLens 只读取已打开的 KakaoTalk 聊天窗口；消息只在内存中处理，不写盘、不联网；日志只记录数量和耗时。",
                     "TalkLens 只讀取已開啟的 KakaoTalk 聊天視窗；訊息只在記憶體中處理，不寫入磁碟、不連網；日誌只記錄數量與耗時。",
                     "TalkLens only reads KakaoTalk chat windows that are already open. Messages are processed in memory only, never written to disk or sent over the network; logs record only counts and timings.",
                     "TalkLens는 이미 열려 있는 카카오톡 채팅창만 읽습니다. 메시지는 메모리에서만 처리되며 디스크에 저장하거나 네트워크로 보내지 않습니다. 로그에는 개수와 소요 시간만 기록됩니다.",
                     "TalkLens は開いている KakaoTalk のチャットウインドウだけを読み取ります。メッセージはメモリ上でのみ処理し、ディスクへの保存やネットワークへの送信は行いません。ログには件数と処理時間だけを記録します。")
        case .sameLanguage:
            return s("原文与目标语言相同，不会翻译", "原文與目標語言相同，不會翻譯",
                     "Source and target are the same; nothing to translate", "원문과 번역 언어가 같아 번역하지 않습니다",
                     "翻訳元と翻訳先が同じため翻訳しません")
        case .pairStatus: return s("状态（{0}）", "狀態（{0}）", "Status ({0})", "상태 ({0})", "状態（{0}）")
        case .download: return s("下载…", "下載…", "Download…", "다운로드…", "ダウンロード…")
        case .installedFor:
            return s("已安装（→{0}）", "已安裝（→{0}）", "Installed (→{0})", "설치됨 (→{0})", "インストール済み（→{0}）")
        case .checking: return s("检测中…", "檢查中…", "Checking…", "확인 중…", "確認中…")
        case .needsDownload: return s("需要下载", "需要下載", "Needs download", "다운로드 필요", "ダウンロードが必要")
        case .nothing: return s("无", "無", "None", "없음", "なし")
        case .engineReady: return s("已安装", "已安裝", "Installed", "설치됨", "インストール済み")
        case .engineUnsupported: return s("不支持", "不支援", "Not supported", "지원 안 됨", "非対応")

        // Onboarding
        case .onboardingWelcome:
            return s("欢迎使用 TalkLens", "歡迎使用 TalkLens", "Welcome to TalkLens", "TalkLens에 오신 것을 환영합니다",
                     "TalkLens へようこそ")
        case .onboardingIntro:
            return s("TalkLens 只读取已经打开的 KakaoTalk 聊天窗口，用本机 Apple 翻译显示译文。不发送、不点击、不联网。",
                     "TalkLens 只讀取已經開啟的 KakaoTalk 聊天視窗，用本機 Apple 翻譯顯示譯文。不傳送、不點按、不連網。",
                     "TalkLens only reads KakaoTalk chat windows that are already open and shows translations made on this Mac by Apple Translation. It never sends, clicks or goes online.",
                     "TalkLens는 이미 열려 있는 카카오톡 채팅창만 읽고, 이 Mac의 Apple 번역으로 번역문을 보여 줍니다. 메시지를 보내거나 클릭하지 않으며 인터넷도 사용하지 않습니다.",
                     "TalkLens は開いている KakaoTalk のチャットウインドウだけを読み取り、この Mac の Apple 翻訳で訳文を表示します。送信、クリック、ネットワーク接続は一切行いません。")
        case .onboardingAXTitle:
            return s("辅助功能权限", "輔助使用權限", "Accessibility Permission", "손쉬운 사용 권한", "アクセシビリティの許可")
        case .onboardingAXGranted: return s("已授权。", "已授權。", "Granted.", "허용되었습니다.", "許可済みです。")
        case .onboardingAXNeeded:
            return s("需要在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 TalkLens。授权后无需重启。",
                     "請在「系統設定」→「隱私權與安全性」→「輔助使用」中勾選 TalkLens。授權後無需重新啟動。",
                     "Turn on TalkLens in System Settings → Privacy & Security → Accessibility. No restart needed afterwards.",
                     "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 TalkLens를 켜 주세요. 허용한 뒤 다시 시작할 필요는 없습니다.",
                     "システム設定 → プライバシーとセキュリティ → アクセシビリティ で TalkLens をオンにしてください。許可後の再起動は不要です。")
        case .onboardingOpenSystemSettings:
            return s("打开系统设置…", "打開系統設定…", "Open System Settings…", "시스템 설정 열기…", "システム設定を開く…")
        case .onboardingLanguageTitle:
            return s("翻译语言（{0} → {1}）", "翻譯語言（{0} → {1}）", "Translation Languages ({0} → {1})",
                     "번역 언어 ({0} → {1})", "翻訳言語（{0} → {1}）")
        case .downloadLanguages:
            return s("下载语言…", "下載語言…", "Download Languages…", "언어 다운로드…", "言語をダウンロード…")
        case .onboardingRecheck: return s("重新检测", "重新檢查", "Check Again", "다시 확인", "再確認")
        case .onboardingKakaoRunning:
            return s("正在运行。打开一个聊天窗口即可。", "正在執行。開啟一個聊天視窗即可。", "Running. Just open a chat window.",
                     "실행 중입니다. 채팅창을 하나 열면 됩니다.", "起動しています。チャットウインドウを開くだけで使えます。")
        case .onboardingKakaoRunningVersion:
            return s("正在运行（版本 {0}）。打开一个聊天窗口即可。", "正在執行（版本 {0}）。開啟一個聊天視窗即可。",
                     "Running (version {0}). Just open a chat window.", "실행 중입니다 (버전 {0}). 채팅창을 하나 열면 됩니다.",
                     "起動しています（バージョン {0}）。チャットウインドウを開くだけで使えます。")
        case .onboardingKakaoNotRunning:
            return s("未运行。请自行打开 KakaoTalk（TalkLens 不会启动它）。", "未執行。請自行開啟 KakaoTalk（TalkLens 不會啟動它）。",
                     "Not running. Please open KakaoTalk yourself (TalkLens never launches it).",
                     "실행 중이 아닙니다. 카카오톡을 직접 실행해 주세요 (TalkLens는 카카오톡을 실행하지 않습니다).",
                     "起動していません。KakaoTalk はご自身で起動してください（TalkLens からは起動しません）。")
        case .onboardingDisclaimer:
            return s("非官方工具，与 Kakao Corp. 无关。", "非官方工具，與 Kakao Corp. 無關。",
                     "Unofficial tool, not affiliated with Kakao Corp.", "비공식 도구이며 Kakao Corp.와 관련이 없습니다.",
                     "非公式ツールであり、Kakao Corp. とは関係ありません。")
        case .onboardingDone: return s("完成", "完成", "Done", "완료", "完了")
        case .onboardingLater: return s("稍后", "稍後", "Later", "나중에", "あとで")
        case .engineInstalledSentence:
            return s("已安装。", "已安裝。", "Installed.", "설치되어 있습니다.", "インストール済みです。")
        case .engineNeedsDownloadSentence:
            return s("需要下载翻译语言（系统会弹出下载对话框）。", "需要下載翻譯語言（系統會跳出下載對話框）。",
                     "The translation languages need to be downloaded (macOS shows a download dialog).",
                     "번역 언어를 다운로드해야 합니다 (시스템 다운로드 창이 열립니다).",
                     "翻訳言語のダウンロードが必要です（システムのダウンロード画面が開きます）。")
        case .engineUnavailable:
            return s("暂不可用：{0}", "暫不可用：{0}", "Unavailable: {0}", "사용할 수 없음: {0}", "利用できません: {0}")
        case .engineHostRequired:
            return s("需要在 TalkLens App 内运行", "需要在 TalkLens App 內執行", "Requires the TalkLens app",
                     "TalkLens 앱에서만 사용할 수 있습니다", "TalkLens アプリ内でのみ利用できます")
        case .engineUnknownSentence:
            return s("未知状态。", "未知狀態。", "Unknown state.", "알 수 없는 상태입니다.", "不明な状態です。")
        case .autoDetected:
            return s("{0}（自动检测）", "{0}（自動偵測）", "{0} (auto-detect)", "{0} (자동 감지)", "{0}（自動検出）")

        // About
        case .aboutVersion: return s("版本 {0}", "版本 {0}", "Version {0}", "버전 {0}", "バージョン {0}")
        case .aboutDescription:
            return s("KakaoTalk 只读翻译伴侣。非官方工具，与 Kakao Corp. 无关（not affiliated with Kakao）。只读、本地、MIT 开源；可能随 KakaoTalk 更新失效，使用风险自负。",
                     "KakaoTalk 唯讀翻譯夥伴。非官方工具，與 Kakao Corp. 無關（not affiliated with Kakao）。唯讀、本機、MIT 開源；可能隨 KakaoTalk 更新而失效，使用風險自負。",
                     "A read-only translation companion for KakaoTalk. Unofficial and not affiliated with Kakao Corp. Read-only, local, MIT-licensed open source; it may stop working when KakaoTalk updates. Use at your own risk.",
                     "카카오톡용 읽기 전용 번역 도우미입니다. 비공식 도구이며 Kakao Corp.와 관련이 없습니다 (not affiliated with Kakao). 읽기 전용, 로컬 처리, MIT 오픈 소스이며 카카오톡 업데이트 후 작동하지 않을 수 있습니다. 사용에 따른 책임은 사용자에게 있습니다.",
                     "KakaoTalk 用の読み取り専用翻訳コンパニオンです。非公式ツールであり、Kakao Corp. とは関係ありません（not affiliated with Kakao）。読み取り専用・ローカル処理・MIT ライセンスのオープンソースです。KakaoTalk のアップデートで動作しなくなる場合があります。ご利用は自己責任でお願いします。")
        case .aboutDiagnostics:
            return s("诊断（仅内存，退出即清）", "診斷（僅存於記憶體，結束即清除）", "Diagnostics (in memory only, cleared on quit)",
                     "진단 (메모리에만 보관, 종료 시 삭제)", "診断（メモリ上のみ、終了時に消去）")
        case .aboutMetric: return s("指标", "指標", "Metric", "지표", "指標")
        case .aboutFollow: return s("侧栏跟随", "側欄跟隨", "Window follow", "창 따라가기", "ウインドウ追従")
        case .aboutNewToTranslation:
            return s("新消息→译文", "新訊息→譯文", "New message → translation", "새 메시지 → 번역", "新着 → 訳文")
        case .aboutRead: return s("快照读取", "快照讀取", "Snapshot read", "스냅숏 읽기", "スナップショット読み取り")
        case .aboutIngest: return s("diff+预处理", "diff+預處理", "Diff + preprocess", "diff+전처리", "差分+前処理")
        case .aboutBudget: return s("预算 {0} ms", "預算 {0} ms", "Budget {0} ms", "목표 {0} ms", "目標 {0} ms")
        case .aboutCounters:
            return s("读取 {0} 次（失败 {1}，兜底轮询 {2}，廉价检查 {3}，隐藏时跳过 {4}），AX 事件 {5} 个。单位 ms。",
                     "讀取 {0} 次（失敗 {1}，備援輪詢 {2}，輕量檢查 {3}，隱藏時略過 {4}），AX 事件 {5} 個。單位 ms。",
                     "Reads: {0} (failed {1}, fallback polls {2}, cheap checks {3}, skipped while hidden {4}); AX events: {5}. Times in ms.",
                     "읽기 {0}회 (실패 {1}, 예비 폴링 {2}, 간이 확인 {3}, 숨김 중 건너뜀 {4}), AX 이벤트 {5}개. 단위 ms.",
                     "読み取り {0} 回（失敗 {1}、予備ポーリング {2}、簡易チェック {3}、非表示中スキップ {4}）、AX イベント {5} 件。単位は ms。")

        // Sidebar and overlay
        case .bannerMissingPairs:
            return s("需要下载翻译语言：{0}", "需要下載翻譯語言：{0}", "Translation languages needed: {0}",
                     "번역 언어 다운로드 필요: {0}", "翻訳言語のダウンロードが必要: {0}")
        case .languagesNotInstalled:
            return s("翻译语言未安装", "翻譯語言未安裝", "Translation languages not installed", "번역 언어가 설치되지 않았습니다",
                     "翻訳言語がインストールされていません")
        case .translationUnavailable:
            return s("翻译不可用", "翻譯無法使用", "Translation unavailable", "번역을 사용할 수 없습니다", "翻訳を利用できません")
        case .guide: return s("引导…", "引導…", "Guide…", "안내…", "ガイド…")
        case .headerCounts:
            return s("{0} 条 · 已译 {1} · 待译 {2}", "{0} 則 · 已譯 {1} · 待譯 {2}", "Messages {0} · Translated {1} · Pending {2}",
                     "메시지 {0} · 번역됨 {1} · 대기 {2}", "{0} 件 · 翻訳済み {1} · 待機 {2}")
        case .headerFailed: return s("失败 {0}", "失敗 {0}", "Failed {0}", "실패 {0}", "失敗 {0}")
        case .settings: return s("设置", "設定", "Settings", "설정", "設定")
        case .openGuide: return s("打开引导…", "打開引導…", "Open Guide…", "안내 열기…", "ガイドを開く…")
        case .resumeTranslation: return s("继续翻译", "繼續翻譯", "Resume", "번역 계속하기", "翻訳を再開")
        case .emptyNoChatWindow:
            return s("打开 KakaoTalk 聊天窗口", "開啟 KakaoTalk 聊天視窗", "Open a KakaoTalk chat window",
                     "카카오톡 채팅창을 열어 주세요", "KakaoTalk のチャットウインドウを開いてください")
        case .emptyStarting: return s("正在连接…", "正在連線…", "Connecting…", "연결하는 중…", "接続中…")
        case .emptyNoMessages:
            return s("暂无可见消息", "暫無可見訊息", "No visible messages yet", "표시할 메시지가 없습니다",
                     "表示できるメッセージはまだありません")
        case .emptyNoPermissionDetail:
            return s("系统设置 → 隐私与安全性 → 辅助功能，勾选 TalkLens。授权后自动继续。",
                     "「系統設定」→「隱私權與安全性」→「輔助使用」，勾選 TalkLens。授權後會自動繼續。",
                     "System Settings → Privacy & Security → Accessibility: turn on TalkLens. It continues automatically once allowed.",
                     "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 TalkLens를 켜 주세요. 허용하면 자동으로 이어집니다.",
                     "システム設定 → プライバシーとセキュリティ → アクセシビリティ で TalkLens をオンにしてください。許可されると自動で再開します。")
        case .emptyNoChatWindowDetail:
            return s("TalkLens 只读取已经打开的聊天窗口。", "TalkLens 只讀取已經開啟的聊天視窗。",
                     "TalkLens only reads chat windows that are already open.", "TalkLens는 이미 열려 있는 채팅창만 읽습니다.",
                     "TalkLens は開いているチャットウインドウだけを読み取ります。")
        case .emptyTranscriptNotFoundDetail:
            return s("KakaoTalk 可能更新了界面结构。", "KakaoTalk 可能更新了介面結構。", "KakaoTalk may have changed its window layout.",
                     "카카오톡 화면 구조가 바뀌었을 수 있습니다.", "KakaoTalk の画面構成が変わった可能性があります。")
        case .newMessages: return s("新消息 {0}", "新訊息 {0}", "New messages: {0}", "새 메시지 {0}", "新着 {0}")
        case .copyTranslation: return s("复制译文", "複製譯文", "Copy Translation", "번역문 복사", "訳文をコピー")
        case .clickToHideOriginal:
            return s("点击收起原文", "按一下收起原文", "Click to hide the original", "클릭하면 원문을 숨깁니다", "クリックで原文を隠す")
        case .clickToShowOriginal:
            return s("点击显示原文", "按一下顯示原文", "Click to show the original", "클릭하면 원문을 표시합니다", "クリックで原文を表示")
        case .hideOriginal: return s("隐藏原文", "隱藏原文", "Hide Original", "원문 숨기기", "原文を隠す")
        case .showOriginal: return s("显示原文", "顯示原文", "Show Original", "원문 보기", "原文を表示")
        case .me: return s("我", "我", "Me", "나", "自分")
        case .attachImages: return s("图片 ×{0}", "圖片 ×{0}", "Images ×{0}", "사진 ×{0}", "画像 ×{0}")
        case .attachLinks: return s("链接 ×{0}", "連結 ×{0}", "Links ×{0}", "링크 ×{0}", "リンク ×{0}")
        case .attachFiles: return s("文件 ×{0}", "檔案 ×{0}", "Files ×{0}", "파일 ×{0}", "ファイル ×{0}")
        case .glossaryBadge: return s("词", "詞", "G", "뜻", "語")

        // Translation failures
        case .failNotInstalledPair:
            return s("需要下载 {0} 翻译语言", "需要下載 {0} 翻譯語言", "Download needed: {0}", "{0} 번역 언어 다운로드 필요",
                     "{0} の翻訳言語のダウンロードが必要です")
        case .failUnsupportedPair:
            return s("Apple 翻译不支持 {0}", "Apple 翻譯不支援 {0}", "Apple Translation doesn't support {0}",
                     "Apple 번역은 {0}을(를) 지원하지 않습니다", "Apple 翻訳は {0} に対応していません")
        case .failUnsupported:
            return s("当前系统不支持此语言对", "目前系統不支援此語言組合", "This language pair isn't supported on this Mac",
                     "이 Mac에서는 이 언어 쌍을 지원하지 않습니다", "この Mac ではこの言語ペアに対応していません")
        case .failGeneric: return s("翻译失败", "翻譯失敗", "Translation failed", "번역 실패", "翻訳に失敗しました")

        // Language download prompt
        case .downloadTitle: return s("翻译语言", "翻譯語言", "Translation Languages", "번역 언어", "翻訳言語")
        case .downloadBody:
            return s("TalkLens 在这台 Mac 上用 Apple 翻译完成翻译，需要先下载以下语言：{0} 和 {1}。不会通过网络发送任何消息内容。",
                     "TalkLens 在這台 Mac 上以 Apple 翻譯完成翻譯，需要先下載以下語言：{0} 和 {1}。不會透過網路傳送任何訊息內容。",
                     "TalkLens translates on this Mac with Apple Translation. It needs these languages downloaded: {0} and {1}. No message content is sent over the network.",
                     "TalkLens는 이 Mac에서 Apple 번역으로 번역합니다. 먼저 다음 언어를 다운로드해야 합니다: {0}, {1}. 메시지 내용은 네트워크로 전송되지 않습니다.",
                     "TalkLens はこの Mac 上の Apple 翻訳で翻訳します。次の言語のダウンロードが必要です: {0}、{1}。メッセージの内容がネットワークに送信されることはありません。")
        case .downloadTryAgain: return s("重试", "重試", "Try Again", "다시 시도", "再試行")
        case .downloadNotYet:
            return s("尚未下载", "尚未下載", "Not downloaded yet", "아직 다운로드하지 않음", "まだダウンロードされていません")
        case .downloadWaiting:
            return s("等待下载…", "等待下載…", "Waiting for download…", "다운로드 대기 중…", "ダウンロードを待っています…")
        case .downloadStillNot:
            return s("仍未安装", "仍未安裝", "Still not installed", "아직 설치되지 않음", "まだインストールされていません")
        case .downloadUnsupported:
            return s("不支持此语言对", "不支援此語言組合", "This language pair is not supported", "이 언어 쌍은 지원되지 않습니다",
                     "この言語ペアには対応していません")
        case .downloadFooter:
            return s("也可以在 系统设置 → 通用 → 语言与地区 → 翻译语言 中下载。",
                     "也可以在「系統設定」→「一般」→「語言與地區」→「翻譯語言」中下載。",
                     "You can also download them in System Settings → General → Language & Region → Translation Languages.",
                     "시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서도 다운로드할 수 있습니다.",
                     "システム設定 → 一般 → 言語と地域 → 翻訳言語 からもダウンロードできます。")
        }
    }
}
