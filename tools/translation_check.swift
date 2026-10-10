// translation_check.swift — reports Apple Translation language availability and, on macOS 26+,
// translates one synthetic sentence with a UI-less session. Read-only, offline.
// Usage: swift tools/translation_check.swift [source] [target]     (default: ko zh-Hans)
// Written without access to a Mac; fix compile errors if any (record the fix in docs/journal.md).
import Foundation
import Translation

let args = CommandLine.arguments
let src = args.count > 1 ? args[1] : "ko"
let tgt = args.count > 2 ? args[2] : "zh-Hans"

if #available(macOS 15.0, *) {
    let availability = LanguageAvailability()
    for (s, t) in [(src, tgt), (src, "en"), ("en", tgt)] {
        let status = await availability.status(from: Locale.Language(identifier: s),
                                               to: Locale.Language(identifier: t))
        print("availability \(s) -> \(t): \(status)")
    }
    if #available(macOS 26.0, *) {
        do {
            let session = TranslationSession(installedSource: Locale.Language(identifier: src),
                                             target: Locale.Language(identifier: tgt))
            let start = Date()
            let response = try await session.translate("내일 랩미팅은 오후 2시로 변경되었습니다.")
            let ms = Date().timeIntervalSince(start) * 1000
            print("sample translation (\(Int(ms)) ms): \(response.targetText)")
        } catch {
            print("UI-less session failed (languages installed?): \(error)")
        }
    } else {
        print("macOS < 26: no UI-less TranslationSession — the app must host a SwiftUI .translationTask")
    }
} else {
    print("Translation framework requires macOS 15+")
}
