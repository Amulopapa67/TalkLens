// SPDX-License-Identifier: MIT
// About + diagnostics: version, disclaimer and in-memory latency numbers (milliseconds only).

import SwiftUI
import TalkLensCore

struct AboutView: View {
    let diagnostics: Diagnostics

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: LogoArt.colorImage(size: 56))
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("TalkLens").font(.title2.weight(.semibold))
                    Text(tr(.aboutVersion, version)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(tr(.aboutDescription))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text(tr(.aboutDiagnostics)).font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text(tr(.aboutMetric)).foregroundStyle(.secondary)
                        Text("n").foregroundStyle(.secondary)
                        Text("p50").foregroundStyle(.secondary)
                        Text("p95").foregroundStyle(.secondary)
                        Text("max").foregroundStyle(.secondary)
                    }
                    statRow(tr(.aboutFollow), diagnostics.followStats, budget: "≤ 100")
                    statRow(tr(.aboutNewToTranslation), diagnostics.translationStats, budget: "≤ 600 / 1500")
                    statRow(tr(.aboutRead), diagnostics.readStats, budget: "≤ 30")
                    statRow(tr(.aboutIngest), diagnostics.ingestStats, budget: "≤ 5")
                }
                .font(.system(size: 11).monospacedDigit())
                Text(tr(.aboutCounters, diagnostics.readCount, diagnostics.readFailureCount, diagnostics.pollReadCount,
                        diagnostics.cheapPollCheckCount, diagnostics.skippedHiddenReadCount, diagnostics.axEventCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func statRow(_ name: String, _ s: LatencyStats, budget: String) -> some View {
        GridRow {
            Text(name).help(tr(.aboutBudget, budget))
            Text("\(s.count)")
            Text(String(format: "%.1f", s.p50))
            Text(String(format: "%.1f", s.p95))
            Text(String(format: "%.1f", s.max))
        }
    }
}
