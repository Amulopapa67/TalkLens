// SPDX-License-Identifier: MIT
// Sidebar UI hosted in OverlayPanel.

import AppKit
import SwiftUI
import TalkLensCore
import TalkLensTranslate

struct SidebarActions {
    var openOnboarding: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    var resume: @MainActor () -> Void
}

/// The only pasteboard write in TalkLens: triggered by the user's "复制译文" click.
@MainActor
enum TranslationClipboard {
    static func copyTranslation(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

struct SidebarView: View {
    let model: SidebarViewModel
    let settings: AppSettings
    let actions: SidebarActions

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, actions: actions)
            Divider()
            if let banner = engineBanner {
                banner
                Divider()
            }
            if model.rows.isEmpty {
                EmptyStateView(model: model, actions: actions)
            } else {
                MessageListView(model: model, settings: settings)
            }
        }
        .frame(minWidth: 200, minHeight: 160)
    }

    private var engineBanner: AnyView? {
        guard let status = model.engineStatus, status != .ready else { return nil }
        let text: String
        if status == .needsDownload {
            text = "翻译语言未安装"
        } else {
            text = "翻译不可用"
        }
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.caption)
                Spacer()
                Button("引导…") { actions.openOnboarding() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        )
    }
}

private struct SidebarHeader: View {
    let model: SidebarViewModel
    let actions: SidebarActions

    var body: some View {
        let counts = model.counts
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chatTitle ?? "TalkLens")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(counts.rows) 条 · 已译 \(counts.done) · 待译 \(counts.pending)"
                     + (counts.failed > 0 ? " · 失败 \(counts.failed)" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if model.status == .paused {
                Label("已暂停", systemImage: "pause.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Button {
                actions.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct EmptyStateView: View {
    let model: SidebarViewModel
    let actions: SidebarActions

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if model.status == .noPermission || model.engineStatus == .needsDownload {
                Button("打开引导…") { actions.openOnboarding() }
            } else if model.status == .paused {
                Button("继续翻译") { actions.resume() }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch model.status {
        case .paused: return "已暂停"
        case .noPermission: return "需要辅助功能权限"
        case .kakaoNotRunning: return "KakaoTalk 未运行"
        case .noChatWindow: return "打开 KakaoTalk 聊天窗口"
        case .transcriptNotFound: return "未找到聊天记录区域"
        case .starting: return "正在连接…"
        case .active:
            return model.engineStatus == .needsDownload ? "翻译语言未安装" : "暂无可见消息"
        }
    }

    private var detail: String? {
        switch model.status {
        case .noPermission: return "系统设置 → 隐私与安全性 → 辅助功能，勾选 TalkLens。授权后自动继续。"
        case .noChatWindow: return "TalkLens 只读取已经打开的聊天窗口。"
        case .transcriptNotFound: return "KakaoTalk 可能更新了界面结构。"
        default: return nil
        }
    }

    private var icon: String {
        switch model.status {
        case .paused: return "pause.circle"
        case .noPermission: return "lock.shield"
        case .kakaoNotRunning: return "moon.zzz"
        case .noChatWindow: return "bubble.left.and.bubble.right"
        case .transcriptNotFound: return "questionmark.folder"
        case .starting: return "hourglass"
        case .active: return "text.bubble"
        }
    }
}

private struct MessageListView: View {
    let model: SidebarViewModel
    let settings: AppSettings

    @State private var followBottom = true
    @State private var nearBottom = true
    @State private var userScrolling = false
    @State private var unseen = 0
    private let bottomID = "talklens.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { row in
                        MessageRowView(row: row, fontSize: settings.fontSize,
                                       originalVisible: model.isOriginalVisible(row.id),
                                       onToggleOriginal: { model.toggleOriginal(row.id) })
                            .id(row.id)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(10)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, isNear in
                nearBottom = isNear
                if isNear {
                    followBottom = true
                    unseen = 0
                } else if userScrolling {
                    followBottom = false
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    userScrolling = true
                default:
                    // A user scroll just ended: follow again only if it ended at the bottom.
                    if userScrolling { followBottom = nearBottom }
                    userScrolling = false
                }
            }
            .onChange(of: model.appendedTick) {
                if followBottom {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                } else {
                    unseen += model.lastAppendedCount
                }
            }
            .onChange(of: model.resetTick) {
                followBottom = true
                unseen = 0
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !followBottom && unseen > 0 {
                    Button {
                        followBottom = true
                        unseen = 0
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Label("新消息 \(unseen)", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }
}

struct MessageRowView: View {
    let row: SidebarRow
    let fontSize: Double
    let originalVisible: Bool
    let onToggleOriginal: () -> Void
    @State private var hovering = false

    var body: some View {
        if row.isSystem {
            Text(row.original.isEmpty ? " " : row.original)
                .font(.system(size: max(9, fontSize - 3)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: row.isMine ? .trailing : .leading, spacing: 3) {
            meta
            content
            if !row.chips.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(Array(row.chips.enumerated()), id: \.offset) { _, chip in
                        Text("\(chip.term) = \(chip.gloss)")
                            .font(.system(size: max(9, fontSize - 3)))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: row.isMine ? .trailing : .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.isMine ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
        )
        .overlay(alignment: .topTrailing) {
            if hovering, let value = row.copyableTranslation {
                Button {
                    TranslationClipboard.copyTranslation(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .help("复制译文")
                .padding(2)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if let value = row.copyableTranslation {
                Button("复制译文") { TranslationClipboard.copyTranslation(value) }
            }
            if row.kind.needsTranslation {
                Button(originalVisible ? "隐藏原文" : "显示原文") { onToggleOriginal() }
            }
        }
    }

    private var meta: some View {
        let author = row.author ?? (row.isMine ? "我" : "")
        let parts = [author, row.timeRaw ?? ""].filter { !$0.isEmpty }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: max(9, fontSize - 3)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        let main = Font.system(size: fontSize)
        let secondary = Font.system(size: max(9, fontSize - 2))
        let align: TextAlignment = row.isMine ? .trailing : .leading
        if row.kind.needsTranslation {
            switch row.translation {
            case .done(let value):
                Text(value).font(main).multilineTextAlignment(align).textSelection(.enabled)
            case .pending:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("翻译中…").font(secondary).foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Text(reason).font(secondary).foregroundStyle(.red)
            case .notNeeded:
                EmptyView()
            }
            if originalVisible {
                Text(row.original).font(secondary).foregroundStyle(.secondary)
                    .multilineTextAlignment(align).textSelection(.enabled)
            }
            Button(originalVisible ? "收起原文" : "原文") { onToggleOriginal() }
                .buttonStyle(.link)
                .font(.system(size: max(9, fontSize - 4)))
        } else {
            if !row.original.isEmpty {
                Text(row.original).font(main).multilineTextAlignment(align).textSelection(.enabled)
            }
            if let note = row.note, row.kind == .jamoOnly || row.kind == .emojiOnly {
                Text(note).font(secondary).foregroundStyle(.secondary)
            }
        }
        if !row.attachments.isEmpty {
            Text(attachmentLabel).font(secondary).foregroundStyle(.secondary)
        }
    }

    private var attachmentLabel: String {
        var parts: [String] = []
        if row.attachments.images > 0 { parts.append("图片 ×\(row.attachments.images)") }
        if row.attachments.links > 0 { parts.append("链接 ×\(row.attachments.links)") }
        if row.attachments.files > 0 { parts.append("文件 ×\(row.attachments.files)") }
        return "[" + parts.joined(separator: " · ") + "]"
    }
}

/// Wrapping row layout for glossary chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > 0 && x + size.width > bounds.width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
