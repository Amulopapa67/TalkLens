// SPDX-License-Identifier: MIT
// os.Logger factory. Log lines carry counts, durations and error codes only — never chat content or titles.

import os

extension Logger {
    static let talkLensSubsystem = "dev.lipper.TalkLens"

    static func talkLens(_ category: String) -> Logger {
        Logger(subsystem: talkLensSubsystem, category: category)
    }
}
