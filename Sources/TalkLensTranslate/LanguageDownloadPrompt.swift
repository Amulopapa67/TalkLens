// SPDX-License-Identifier: MIT
// SwiftUI view that asks the system to download missing translation languages
// (`.translationTask` + `prepareTranslation()`); must be shown in a visible window.
// STUB — translate-dev owns this file.

import SwiftUI

public struct LanguageDownloadPrompt: View {
    let source: Locale.Language
    let target: Locale.Language
    let onFinish: @MainActor (Bool) -> Void

    /// `onFinish(true)` when the languages are installed afterwards.
    public init(source: Locale.Language, target: Locale.Language, onFinish: @escaping @MainActor (Bool) -> Void) {
        self.source = source
        self.target = target
        self.onFinish = onFinish
    }

    public var body: some View {
        Text("Language download not implemented yet")
    }
}
