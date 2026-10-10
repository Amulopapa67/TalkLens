// SPDX-License-Identifier: MIT
// Redaction for every log line and default CLI output: message text and chat titles become
// "<text len=N ko>" / "<title len=N ko>" placeholders.
// STUB — core-dev: finish (time/date labels may stay verbatim, as in tools/kakao_ax_probe.swift).

import Foundation

public enum Redactor {
    /// "<text len=N [ko] [zh] [url]>"
    public static func redact(_ text: String) -> String {
        "<text len=\(text.count)>"
    }

    /// Redacts a chat window title. KakaoTalk's own main-window titles ("KakaoTalk", "카카오톡") stay verbatim.
    public static func redactTitle(_ title: String) -> String {
        "<title len=\(title.count)>"
    }

    /// First 6 hex chars of a SHA-256, for log correlation without content.
    public static func shortHash(_ text: String) -> String {
        String(MessageIdentity.sha256Hex(text).prefix(6))
    }
}
