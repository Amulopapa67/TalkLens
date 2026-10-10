// SPDX-License-Identifier: MIT
// Time and date label parsing (docs/architecture.md §4.5).
// STUB — core-dev: implement and test.

import Foundation

public enum TimeLabelParser {
    /// Extracts a time token ("오후 3:12", "下午 3:12", "3:12 PM", "15:12") from a label, or nil.
    public static func extractTime(from label: String) -> String? { nil }

    /// Minutes since midnight for a time token, or nil.
    public static func minuteOfDay(_ timeRaw: String) -> Int? { nil }

    /// AXHelp tooltip ("2026. 6. 2." or "2026-06-02") → "2026-06-02".
    public static func parseHelpDate(_ text: String) -> String? { nil }

    /// Date divider row text ("2026년 10월 10일 금요일", "10월 10일", "2026. 10. 10.", "2026-10-10") → "YYYY-MM-DD".
    /// `referenceYear` fills in a missing year.
    public static func parseDividerDate(_ text: String, referenceYear: Int) -> String? { nil }
}
