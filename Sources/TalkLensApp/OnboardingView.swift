// SPDX-License-Identifier: MIT
// Permission and language onboarding (F2). Polls permission / KakaoTalk state once per second while open.

import KakaoAX
import Observation
import SwiftUI
import TalkLensCore
import TalkLensTranslate

@MainActor
@Observable
final class OnboardingModel {
    private(set) var accessibilityGranted = AccessibilityAccess.isGranted
    private(set) var kakaoRunning = KakaoProcess.isRunning
    private(set) var kakaoVersion: String? = KakaoProcess.version
    private(set) var engineStatus: EngineStatus?
    private(set) var checkingEngine = false
    var showDownloadPrompt = false

    @ObservationIgnored private let service: TranslationService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?
    @ObservationIgnored var onEngineStatus: ((EngineStatus) -> Void)?

    init(service: TranslationService) {
        self.service = service
    }

    var allGood: Bool { accessibilityGranted && engineStatus == .ready && kakaoRunning }

    func start() {
        refreshEngine()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-resolve the weak reference each tick so the model is never kept alive across the sleep.
                guard self?.poll() != nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        let granted = AccessibilityAccess.isGranted
        if granted && !accessibilityGranted { onAccessibilityGranted?() }
        accessibilityGranted = granted
        kakaoRunning = KakaoProcess.isRunning
        kakaoVersion = kakaoRunning ? KakaoProcess.version : nil
    }

    func requestAccessibility() {
        AccessibilityAccess.requestPrompt()
        AccessibilityAccess.openSystemSettings()
    }

    func refreshEngine() {
        checkingEngine = true
        let service = self.service
        Task { [weak self] in
            let status = await service.status()
            guard let self else { return }
            self.engineStatus = status
            self.checkingEngine = false
            self.onEngineStatus?(status)
        }
    }

    /// Source of the checked pair: the chosen source, or Korean when the source is auto-detected.
    var sourceLanguage: Locale.Language = Locale.Language(identifier: LanguageCatalog.fallbackSource)
}

struct OnboardingView: View {
    let model: OnboardingModel
    let target: Locale.Language
    let sourceName: String
    let targetName: String
    let done: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 TalkLens")
                .font(.title2.weight(.semibold))
            Text("TalkLens 只读取已经打开的 KakaoTalk 聊天窗口，用本机 Apple 翻译显示译文。不发送、不点击、不联网。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(ok: model.accessibilityGranted, title: "辅助功能权限",
                 detail: model.accessibilityGranted
                    ? "已授权。"
                    : "需要在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 TalkLens。授权后无需重启。") {
                if !model.accessibilityGranted {
                    Button("打开系统设置…") { model.requestAccessibility() }
                }
            }

            step(ok: model.engineStatus == .ready, title: "翻译语言（\(sourceName) → \(targetName)）",
                 detail: engineDetail) {
                HStack {
                    if model.engineStatus == .needsDownload {
                        Button("下载语言…") { model.showDownloadPrompt = true }
                    }
                    Button("重新检测") { model.refreshEngine() }
                        .disabled(model.checkingEngine)
                }
            }
            if model.showDownloadPrompt {
                LanguageDownloadPrompt(source: model.sourceLanguage, target: target) { _ in
                    model.showDownloadPrompt = false
                    model.refreshEngine()
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }

            step(ok: model.kakaoRunning, title: "KakaoTalk",
                 detail: model.kakaoRunning
                    ? "正在运行" + (model.kakaoVersion.map { "（版本 \($0)）" } ?? "") + "。打开一个聊天窗口即可。"
                    : "未运行。请自行打开 KakaoTalk（TalkLens 不会启动它）。") {
                EmptyView()
            }

            Spacer(minLength: 0)
            HStack {
                Text("非官方工具，与 Kakao Corp. 无关。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.allGood ? "完成" : "稍后") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var engineDetail: String {
        guard let status = model.engineStatus else { return "检测中…" }
        if status == .ready { return "已安装。" }
        if status == .needsDownload { return "需要下载翻译语言（系统会弹出下载对话框）。" }
        if case .unsupported(let reason) = status { return "暂不可用：\(reason)" }
        return "未知状态。"
    }

    @ViewBuilder
    private func step<Accessory: View>(ok: Bool, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }
}
