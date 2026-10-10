// SPDX-License-Identifier: MIT
// Percentile helpers for timing measurements (durations only — never message content).

import Foundation

public struct LatencyStats: Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let max: Double
    public let mean: Double

    /// Nearest-rank percentiles over `samples` (any unit; callers use milliseconds).
    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        p50 = LatencyStats.percentile(sorted, 0.50)
        p95 = LatencyStats.percentile(sorted, 0.95)
        max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }

    /// Nearest-rank percentile of an ascending-sorted array; 0 for empty input.
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }

    public var summary: String {
        String(format: "n=%d p50=%.2fms p95=%.2fms max=%.2fms", count, p50, p95, max)
    }
}

/// Monotonic stopwatch.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var elapsedMilliseconds: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
