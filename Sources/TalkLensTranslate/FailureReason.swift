// SPDX-License-Identifier: MIT
// Short, user-facing reasons for failed translations in the app's UI language (D-024). Content-free: only
// language names.

import Foundation
import TalkLensCore

public enum FailureReason {
    /// e.g. "需要下载 日语→简体中文 翻译语言" / "Download needed: Japanese→Chinese (Simplified)" for a pair that is
    /// not installed.
    public static func describe(_ error: TranslationEngineError, pair: LanguagePair?,
                                language: UILanguage = .zhHans) -> String {
        switch error {
        case .notInstalled:
            if let pair { return UIStrings.text(.failNotInstalledPair, language, UIStrings.pairName(pair, language)) }
            return UIStrings.text(.languagesNotInstalled, language)
        case .unsupported:
            if let pair { return UIStrings.text(.failUnsupportedPair, language, UIStrings.pairName(pair, language)) }
            return UIStrings.text(.failUnsupported, language)
        case .cancelled, .failed:
            return UIStrings.text(.failGeneric, language)
        }
    }

    /// Short banner text aggregating every pair that needs a download.
    public static func missingPairsBanner(_ pairs: [LanguagePair], language: UILanguage = .zhHans) -> String? {
        guard !pairs.isEmpty else { return nil }
        let names = UIStrings.list(pairs.map { UIStrings.pairName($0, language) }, language)
        return UIStrings.text(.bannerMissingPairs, language, names)
    }

    /// Localized reason for an engine status of `.unsupported(reason)` (the raw reason is technical English).
    public static func unsupportedStatus(_ reason: String, language: UILanguage) -> String {
        reason == AppleTranslationEngine.hostRequiredReason
            ? UIStrings.text(.engineHostRequired, language)
            : UIStrings.text(.failUnsupported, language)
    }
}
