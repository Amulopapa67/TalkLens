// SPDX-License-Identifier: MIT
// Settings window (F7). Preferences only; chat content is never persisted.

import SwiftUI
import TalkLensCore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let glossary: GlossaryStore
    let loginItem: LoginItemController
    let reloadGlossary: @MainActor () -> Void

    var body: some View {
        Form {
            Section("翻译") {
                Picker("目标语言", selection: $settings.targetLanguage) {
                    ForEach(AppSettings.targetLanguages, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                Toggle("默认显示原文", isOn: $settings.showOriginal)
                Text("源语言固定为韩语。翻译完全在本机进行（Apple 翻译），不联网。")
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
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: $settings.opacity, in: AppSettings.opacityRange, step: 0.05)
                        Text("\(Int((settings.opacity * 100).rounded()))%").monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("常驻显示（KakaoTalk 不在前台时也显示）", isOn: $settings.pinned)
                Toggle("显示侧栏", isOn: $settings.sidebarVisible)
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
}
