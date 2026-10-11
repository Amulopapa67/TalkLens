// SPDX-License-Identifier: MIT
// Short, user-facing (Chinese) reasons for failed translations. Content-free: only language names.

import Foundation
import TalkLensCore

public enum FailureReason {
    /// e.g. "需要下载 日本語→中文（简体）翻译语言" for a pair that is not installed.
    public static func describe(_ error: TranslationEngineError, pair: LanguagePair?) -> String {
        switch error {
        case .notInstalled:
            if let pair { return "需要下载 \(pair.displayName) 翻译语言" }
            return "翻译语言未安装"
        case .unsupported:
            if let pair { return "Apple 翻译不支持 \(pair.displayName)" }
            return "当前系统不支持此语言对"
        case .cancelled, .failed:
            return "翻译失败"
        }
    }

    /// Short banner text aggregating every pair that needs a download.
    public static func missingPairsBanner(_ pairs: [LanguagePair]) -> String? {
        guard !pairs.isEmpty else { return nil }
        return "需要下载翻译语言：" + pairs.map(\.displayName).joined(separator: "、")
    }
}
