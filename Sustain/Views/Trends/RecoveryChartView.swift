import Charts
import SwiftUI

/// Sleep and HRV trend, with dose days marked, so a user can look at both
/// together and judge for themselves whether they line up. As of
/// 2026-08-08 this also surfaces one plain descriptive comparison — average
/// sleep/HRV on days a side effect was logged vs other days — but still
/// deliberately stops short of computing or asserting an actual correlation
/// or causation claim; see `sideEffectComparisonText` below for the exact
/// line being walked. Same two-small-charts layout as
/// `BodyCompositionChartView` (different units, no clean shared axis), and
/// the same "expect entries pre-sorted ascending by date" convention as
/// every other chart here.
///
/// Resting heart rate is imported (`RecoveryEntry.restingHeartRateBPM`) but
/// not charted in this first version — sleep and HRV are the two metrics
/// `Sustain-Subscription-Payer-Features-Report-2026-08.md` §4 specifically
/// named (matching Oura's GLP-1 Insights precedent), and a third chart
/// crowded the card without a clear enough reason to add it yet. The data is
/// there for a future pass if it turns out to matter.
struct RecoveryChartView: View {
    let entries: [RecoveryEntry]
    /// Dates of logged (non-skipped) doses within the same visible window as
    /// `entries` — drawn as light vertical rule marks across both charts so
    /// dose timing and recovery trend are visually side by side without the
    /// view itself claiming they're related.
    let doseDates: [Date]
    /// Dates of logged side-effect entries in the same visible window —
    /// added 2026-08-08 to close the one piece of
    /// `Sustain-Subscription-Payer-Features-Report-2026-08.md` §4 that
    /// shipped without it: "a simple 'your side-effect entries cluster
    /// around days with lower HRV/sleep' observation." Deliberately a plain
    /// two-group average comparison, not a statistical test — see
    /// `sideEffectComparisonText` below for why that's a real distinction,
    /// not just hedging language.
    let sideEffectDates: [Date]

    private var sleepEntries: [RecoveryEntry] {
        entries.filter { $0.sleepHours != nil }
    }

    private var hrvEntries: [RecoveryEntry] {
        entries.filter { $0.hrvMilliseconds != nil }
    }

    private func isSideEffectDay(_ date: Date) -> Bool {
        sideEffectDates.contains { Calendar.current.isDate($0, inSameDayAs: date) }
    }

    /// Plain mean of `value` across whichever half of `source` matches
    /// `onSideEffectDays`, or nil if fewer than 3 entries fall in that half.
    /// The floor of 3 isn't a claim of statistical significance — it's just
    /// enough to keep a single unusual night from reading as a "pattern."
    /// This function computes an average, nothing more; the causation
    /// caveat lives entirely in the text the caller builds from it.
    private func groupedAverage(
        _ source: [RecoveryEntry],
        value: (RecoveryEntry) -> Double?,
        onSideEffectDays: Bool
    ) -> Double? {
        let values = source
            .filter { isSideEffectDay($0.date) == onSideEffectDays }
            .compactMap(value)
        guard values.count >= 3 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Two-group comparison text — "on days you logged a side effect vs.
    /// other days" — for whichever of sleep/HRV has enough data on both
    /// sides. Returns nil (rendering nothing) unless there's at least one
    /// side-effect log in the visible window AND at least 3 recovery
    /// entries on each side of that split; a thin sample says "not enough
    /// data yet," not a manufactured pattern.
    private var sideEffectComparisonText: String? {
        guard !sideEffectDates.isEmpty else { return nil }
        var lines: [String] = []
        if let onDays = groupedAverage(hrvEntries, value: { $0.hrvMilliseconds }, onSideEffectDays: true),
           let otherDays = groupedAverage(hrvEntries, value: { $0.hrvMilliseconds }, onSideEffectDays: false) {
            lines.append(String(format: "HRV averaged %.0f ms on days you logged a side effect, vs %.0f ms on other days.", onDays, otherDays))
        }
        if let onDays = groupedAverage(sleepEntries, value: { $0.sleepHours }, onSideEffectDays: true),
           let otherDays = groupedAverage(sleepEntries, value: { $0.sleepHours }, onSideEffectDays: false) {
            lines.append(String(format: "Sleep averaged %.1f hours on days you logged a side effect, vs %.1f hours on other days.", onDays, otherDays))
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sleep & recovery")
                .font(.headline)

            if sleepEntries.count < 2 && hrvEntries.count < 2 {
                emptyState
            } else {
                if sleepEntries.count >= 2 {
                    metricChart(
                        title: "Sleep (hours)",
                        entries: sleepEntries,
                        value: { $0.sleepHours ?? 0 },
                        color: Theme.primary
                    )
                }
                if hrvEntries.count >= 2 {
                    metricChart(
                        title: "HRV (ms)",
                        entries: hrvEntries,
                        value: { $0.hrvMilliseconds ?? 0 },
                        color: Theme.warning
                    )
                }
                Text("Dose days are marked with a vertical line. This shows your recovery data alongside your dose timing so you can look at both together — it isn't a claim that one affects the other, and it's never a reason to change your dose. Talk to your prescriber about any pattern that concerns you.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let sideEffectComparisonText {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Label("What this looks like on days you logged a side effect", systemImage: "arrow.left.arrow.right")
                            .font(.caption.weight(.semibold))
                        Text(sideEffectComparisonText)
                            .font(.caption)
                        Text("These are simple averages, not a statistical test — they don't show that one causes the other, and a short logging history can make normal night-to-night variation look like a pattern. Talk to your prescriber about anything that concerns you.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func metricChart(
        title: String,
        entries: [RecoveryEntry],
        value: @escaping (RecoveryEntry) -> Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                // Drawn first so the rule marks sit behind the recovery
                // line, not on top of it — dose timing is context here, not
                // the focal series.
                ForEach(doseDates, id: \.self) { date in
                    RuleMark(x: .value("Dose", date))
                        .foregroundStyle(Theme.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(entries) { entry in
                    LineMark(
                        x: .value("Date", entry.date),
                        y: .value(title, value(entry))
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .symbol(.circle)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 140)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bed.double.fill")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No sleep or HRV data yet")
                .font(.caption.weight(.semibold))
            Text("If you wear an Apple Watch, Oura, Whoop, or another device that syncs sleep or heart rate variability to Health, entries will appear here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

#Preview {
    RecoveryChartView(
        entries: (0..<14).map { i in
            RecoveryEntry(
                date: Calendar.current.date(byAdding: .day, value: -i, to: .now) ?? .now,
                sleepHours: 6.5 + Double.random(in: -1...1),
                hrvMilliseconds: 45 + Double.random(in: -8...8)
            )
        },
        doseDates: [
            Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now,
            .now,
        ],
        sideEffectDates: [
            Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now,
            Calendar.current.date(byAdding: .day, value: -5, to: .now) ?? .now,
            Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now,
        ]
    )
    .padding()
}
