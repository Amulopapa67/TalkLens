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
                Image(systemName: "character.bubble").font(.system(size: 32))
                VStack(alignment: .leading) {
                    Text("TalkLens").font(.title2.weight(.semibold))
                    Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("KakaoTalk 只读翻译伴侣。非官方工具，与 Kakao Corp. 无关（not affiliated with Kakao）。只读、本地、MIT 开源；可能随 KakaoTalk 更新失效，使用风险自负。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("诊断（仅内存，退出即清）").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("指标").foregroundStyle(.secondary)
                        Text("n").foregroundStyle(.secondary)
                        Text("p50").foregroundStyle(.secondary)
                        Text("p95").foregroundStyle(.secondary)
                        Text("max").foregroundStyle(.secondary)
                    }
                    statRow("侧栏跟随", diagnostics.followStats, budget: "≤ 100")
                    statRow("新消息→译文", diagnostics.translationStats, budget: "≤ 600 / 1500")
                    statRow("快照读取", diagnostics.readStats, budget: "≤ 30")
                    statRow("diff+预处理", diagnostics.ingestStats, budget: "≤ 5")
                }
                .font(.system(size: 11).monospacedDigit())
                Text("读取 \(diagnostics.readCount) 次（失败 \(diagnostics.readFailureCount)，兜底轮询 \(diagnostics.pollReadCount)，廉价检查 \(diagnostics.cheapPollCheckCount)，隐藏时跳过 \(diagnostics.skippedHiddenReadCount)），AX 事件 \(diagnostics.axEventCount) 个。单位 ms。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func statRow(_ name: String, _ s: LatencyStats, budget: String) -> some View {
        GridRow {
            Text(name).help("预算 \(budget) ms")
            Text("\(s.count)")
            Text(String(format: "%.1f", s.p50))
            Text(String(format: "%.1f", s.p95))
            Text(String(format: "%.1f", s.max))
        }
    }
}
