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
        let language = uiLanguage
        Form {
            Section(tr(.sectionGeneral)) {
                Picker(tr(.uiLanguage), selection: $settings.uiLanguage) {
                    ForEach(UILanguageSetting.allCases) { option in
                        Text(AppDelegate.uiLanguageLabel(option, language)).tag(option)
                    }
                }
                Text(tr(.uiLanguageFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr(.sectionTranslation)) {
                // Auto-detect first, then the catalog languages; Korean is the default (D-024).
                Picker(tr(.sourceLanguage), selection: $settings.sourceLanguage) {
                    ForEach(LanguageCatalog.sourceOptions(supported: languages.supported)) { option in
                        Text(UIStrings.languageOptionLabel(option.id, language)).tag(option.id)
                    }
                }
                Picker(tr(.targetLanguage), selection: $settings.targetLanguage) {
                    ForEach(LanguageCatalog.targetOptions(supported: languages.supported)) { option in
                        Text(UIStrings.languageOptionLabel(option.id, language)).tag(option.id)
                    }
                }
                languageStatusRows
                if let pair = downloadPair {
                    LanguageDownloadPrompt(source: Locale.Language(identifier: pair.source),
                                           target: Locale.Language(identifier: pair.target),
                                           language: language) { installed in
                        downloadPair = nil
                        if installed { languagesInstalled() }
                        Task { await languages.refresh(source: settings.sourceLanguage, target: settings.targetLanguage) }
                    }
                    .id(pair)
                }
                Toggle(tr(.showOriginalByDefault), isOn: $settings.showOriginal)
                Text(tr(.translationFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task(id: settings.sourceLanguage + "|" + settings.targetLanguage) {
                downloadPair = nil
                await languages.refresh(source: settings.sourceLanguage, target: settings.targetLanguage)
            }

            Section(tr(.displayMode)) {
                Picker(tr(.displayMode), selection: $settings.displayMode) {
                    ForEach(AppSettings.DisplayMode.allCases, id: \.self) { mode in
                        Text(tr(mode.nameKey)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(tr(.displayModeFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr(.displayModeSidebar)) {
                Picker(tr(.panelEdge), selection: $settings.edge) {
                    ForEach(PanelEdge.allCases, id: \.self) { edge in
                        Text(tr(AppSettings.edgeKey(edge))).tag(edge)
                    }
                }
                LabeledContent(tr(.panelWidth)) {
                    HStack {
                        Slider(value: $settings.panelWidth, in: AppSettings.panelWidthRange, step: 10)
                        Text("\(Int(settings.panelWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent(tr(.fontSize)) {
                    HStack {
                        Slider(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1)
                        Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent(tr(.backgroundOpacity)) {
                    HStack {
                        Slider(value: $settings.opacity, in: AppSettings.opacityRange, step: 0.05)
                        Text("\(Int((settings.opacity * 100).rounded()))%").monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle(tr(.pinnedLong), isOn: $settings.pinned)
                Toggle(tr(.showTranslations), isOn: $settings.sidebarVisible)
            }

            Section(tr(.sectionGlossary)) {
                Toggle(tr(.glossaryEnabled), isOn: $settings.glossaryEnabled)
                LabeledContent(tr(.glossaryEntries)) {
                    Text(tr(.glossaryCounts, glossary.bundled.entries.count, glossary.user.entries.count))
                        .monospacedDigit()
                }
                HStack {
                    Button(tr(.glossaryEdit)) { glossary.openUserGlossary() }
                    Button(tr(.glossaryReload)) { reloadGlossary() }
                }
                if let error = glossary.lastError {
                    Text(tr(error)).font(.caption).foregroundStyle(.red)
                }
                Text(tr(.glossaryFooter, "~/Library/Application Support/TalkLens/glossary.json"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr(.sectionSystem)) {
                Toggle(tr(.launchAtLogin), isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                LabeledContent(tr(.status)) { Text(loginItem.statusDescription) }
                if loginItem.status == .requiresApproval {
                    Button(tr(.openLoginItems)) { loginItem.openLoginItemsSettings() }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section(tr(.sectionPrivacy)) {
                Text(tr(.privacyFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 600)
        .onAppear { loginItem.refresh() }
    }

    @ViewBuilder
    private var languageStatusRows: some View {
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        let language = uiLanguage
        if source != LanguageCatalog.autoID && LanguageCatalog.sameFamily(source, target) {
            LabeledContent(tr(.status)) { Text(tr(.sameLanguage)).foregroundStyle(.orange) }
        } else if source != LanguageCatalog.autoID {
            let status = languages.statuses[source]
            LabeledContent(tr(.pairStatus, UIStrings.pairName(LanguagePair(source: source, target: target), language))) {
                HStack {
                    Text(LanguageStatusModel.statusText(status))
                        .foregroundStyle(status == .ready ? Color.secondary : Color.orange)
                    if status == .needsDownload {
                        Button(tr(.download)) { downloadPair = LanguagePair(source: source, target: target) }
                    }
                }
            }
        } else {
            LabeledContent(tr(.installedFor, UIStrings.languageName(target, language))) {
                Text(languages.checking && languages.statuses.isEmpty ? tr(.checking)
                     : names(languages.installed)).multilineTextAlignment(.trailing)
            }
            if !languages.needsDownload.isEmpty {
                LabeledContent(tr(.needsDownload)) {
                    Menu(tr(.download)) {
                        ForEach(languages.needsDownload, id: \.self) { s in
                            Button(UIStrings.pairName(LanguagePair(source: s, target: target), language)) {
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
        let language = uiLanguage
        return ids.isEmpty ? tr(.nothing) : UIStrings.list(ids.map { UIStrings.languageName($0, language) }, language)
    }
}
