// SPDX-License-Identifier: MIT
// Settings window (F7). Preferences only; chat content is never persisted.

import SwiftUI
import TalkLensCore
import TalkLensTranslate

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let glossary: GlossaryStore
    let loginItem: LoginItemController
    let reloadGlossary: @MainActor () -> Void
    let languages: LanguageStatusModel
    /// Called after a download prompt reports the pair installed.
    let languagesInstalled: @MainActor () -> Void
    @State private var downloadPair: LanguagePair?

    var body: some View {
        Form {
            Section("翻译") {
                Picker("原文语言", selection: $settings.sourceLanguage) {
                    ForEach(LanguageCatalog.sourceOptions(supported: languages.supported)) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                Picker("目标语言", selection: $settings.targetLanguage) {
                    ForEach(LanguageCatalog.targetOptions(supported: languages.supported)) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                languageStatusRows
                if let pair = downloadPair {
                    LanguageDownloadPrompt(source: Locale.Language(identifier: pair.source),
                                           target: Locale.Language(identifier: pair.target)) { installed in
                        downloadPair = nil
                        if installed { languagesInstalled() }
                        Task { await languages.refresh(source: settings.sourceLanguage, target: settings.targetLanguage) }
                    }
                    .id(pair)
                }
                Toggle("默认显示原文", isOn: $settings.showOriginal)
                Text("自动检测：逐条判断语言，已经是目标语言的消息不翻译；词表注释只用于韩语消息、中文译文。翻译完全在本机进行（Apple 翻译），不联网。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task(id: settings.sourceLanguage + "|" + settings.targetLanguage) {
                downloadPair = nil
                await languages.refresh(source: settings.sourceLanguage, target: settings.targetLanguage)
            }

            Section("显示方式") {
                Picker("显示方式", selection: $settings.displayMode) {
                    ForEach(AppSettings.DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("沉浸式：译文直接盖在 KakaoTalk 的气泡上，滚动时跟随；按住 ⌥ 显示原文，鼠标悬停在气泡上可看原文和词表注释。窗口不拦截点击。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("侧栏") {
                Picker("贴靠位置", selection: $settings.edge) {
                    ForEach(PanelEdge.allCases, id: \.self) { edge in
                        Text(AppSettings.edgeName(edge)).tag(edge)
                    }
                }
                LabeledContent("侧栏宽度") {
                    HStack {
                        Slider(value: $settings.panelWidth, in: AppSettings.panelWidthRange, step: 10)
                        Text("\(Int(settings.panelWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("字号") {
                    HStack {
                        Slider(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1)
                        Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("背景不透明度") {
                    HStack {
                        Slider(value: $settings.opacity, in: AppSettings.opacityRange, step: 0.05)
                        Text("\(Int((settings.opacity * 100).rounded()))%").monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("常驻显示（KakaoTalk 不在前台时也显示）", isOn: $settings.pinned)
                Toggle("显示译文（侧栏或沉浸式覆盖）", isOn: $settings.sidebarVisible)
            }

            Section("词表") {
                Toggle("启用词表注释与展开", isOn: $settings.glossaryEnabled)
                LabeledContent("条目") {
                    Text("内置 \(glossary.bundled.entries.count) · 用户 \(glossary.user.entries.count)")
                        .monospacedDigit()
                }
                HStack {
                    Button("编辑用户词表…") { glossary.openUserGlossary() }
                    Button("重新加载词表") { reloadGlossary() }
                }
                if let error = glossary.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("用户词表位于 ~/Library/Application Support/TalkLens/glossary.json，同名条目覆盖内置条目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("系统") {
                Toggle("登录时启动 TalkLens", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                LabeledContent("状态") { Text(loginItem.statusDescription) }
                if loginItem.status == .requiresApproval {
                    Button("打开登录项设置…") { loginItem.openLoginItemsSettings() }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("隐私") {
                Text("TalkLens 只读取已打开的 KakaoTalk 聊天窗口；消息只在内存中处理，不写盘、不联网；日志只记录数量和耗时。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 560)
        .onAppear { loginItem.refresh() }
    }

    @ViewBuilder
    private var languageStatusRows: some View {
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        if source != LanguageCatalog.autoID && LanguageCatalog.sameFamily(source, target) {
            LabeledContent("状态") { Text("原文与目标语言相同，不会翻译").foregroundStyle(.orange) }
        } else if source != LanguageCatalog.autoID {
            let status = languages.statuses[source]
            LabeledContent("状态（\(LanguagePair(source: source, target: target).displayName)）") {
                HStack {
                    Text(LanguageStatusModel.statusText(status))
                        .foregroundStyle(status == .ready ? Color.secondary : Color.orange)
                    if status == .needsDownload {
                        Button("下载…") { downloadPair = LanguagePair(source: source, target: target) }
                    }
                }
            }
        } else {
            LabeledContent("已安装（→\(LanguageCatalog.displayName(target))）") {
                Text(languages.checking && languages.statuses.isEmpty ? "检测中…"
                     : names(languages.installed)).multilineTextAlignment(.trailing)
            }
            if !languages.needsDownload.isEmpty {
                LabeledContent("需要下载") {
                    Menu("下载…") {
                        ForEach(languages.needsDownload, id: \.self) { s in
                            Button(LanguagePair(source: s, target: target).displayName) {
                                downloadPair = LanguagePair(source: s, target: target)
                            }
                        }
                    }
                    .fixedSize()
                }
                Text(names(languages.needsDownload))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func names(_ ids: [String]) -> String {
        ids.isEmpty ? "无" : ids.map(LanguageCatalog.displayName).joined(separator: "、")
    }
}
