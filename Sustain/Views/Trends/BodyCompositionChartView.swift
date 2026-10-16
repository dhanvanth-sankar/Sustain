import Charts
import SwiftUI

/// `entries` is expected pre-sorted ascending by date, same convention as
/// `WeightChartView` — its one call site (`TrendsView`) feeds it straight from
/// `@Query(sort: \BodyCompositionEntry.date)`.
///
/// Renders body fat % and lean mass as two separate small charts rather than
/// one dual-axis chart — body fat is a percentage (0-100 scale) and lean mass
/// is in pounds, and Swift Charts doesn't have a clean built-in way to show
/// two independent y-axes on one chart without the reader misreading which
/// scale a given line belongs to. Two clearly-labeled charts stacked
/// vertically is less visually impressive but unambiguous, which matters more
/// for a health metric someone is tracking their actual progress against.
///
/// **Single-entry display, added 2026-08-09.** Real bug, reported directly:
/// right after saving a body-fat estimate from `BodyScanView`, this card
/// still said "No body composition data yet" — the saved value wasn't
/// visible anywhere. Root cause: every metric here only ever rendered as a
/// line chart, gated behind `count >= 2` (a single point can't draw a
/// line), and the `else` branch for "not enough points" was the same
/// generic empty state used for genuinely zero data, so a real first data
/// point and no data at all were indistinguishable on screen. Before this
/// feature existed that gap was rarely visible in practice — the only way
/// data arrived was periodic HealthKit smart-scale imports, which usually
/// already had several accumulated samples by the time anyone opened this
/// card. A single deliberate AI photo estimate makes "exactly one point"
/// a real, common first-run state that needs its own honest display, not
/// a chart it can't support and not a message telling the user nothing is
/// there.
struct BodyCompositionChartView: View {
    let entries: [BodyCompositionEntry]

    private var bodyFatEntries: [BodyCompositionEntry] {
        entries.filter { $0.bodyFatPercent != nil }
    }

    private var leanMassEntries: [BodyCompositionEntry] {
        entries.filter { $0.leanMassLbs != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Body composition")
                .font(.headline)

            if bodyFatEntries.isEmpty && leanMassEntries.isEmpty {
                emptyState
            } else {
                bodyFatSection
                leanMassSection
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var bodyFatSection: some View {
        if bodyFatEntries.count >= 2 {
            metricChart(
                title: "Body fat %",
                entries: bodyFatEntries,
                value: { $0.bodyFatPercent ?? 0 },
                color: Theme.warning
            )
        } else if let latest = bodyFatEntries.last, let value = latest.bodyFatPercent {
            singleValueRow(title: "Body fat %", valueText: value.formatted(.number.precision(.fractionLength(0...1))) + "%", date: latest.date, color: Theme.warning)
        }
    }

    @ViewBuilder
    private var leanMassSection: some View {
        if leanMassEntries.count >= 2 {
            metricChart(
                title: "Lean mass (lb)",
                entries: leanMassEntries,
                value: { $0.leanMassLbs ?? 0 },
                color: Theme.primary
            )
        } else if let latest = leanMassEntries.last, let value = latest.leanMassLbs {
            singleValueRow(title: "Lean mass", valueText: value.formatted(.number.precision(.fractionLength(0...1))) + " lb", date: latest.date, color: Theme.primary)
        }
    }

    /// One saved reading, shown plainly rather than forced into a chart
    /// that needs at least two points to mean anything. `date` is shown so
    /// it reads as "this is what you logged and when," the same
    /// information a two-point chart's single dot would otherwise convey.
    private func singleValueRow(title: String, valueText: String, date: Date, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(valueText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metricChart(
        title: String,
        entries: [BodyCompositionEntry],
        value: @escaping (BodyCompositionEntry) -> Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(entries) { entry in
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value(title, value(entry))
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
                .symbol(.circle)
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
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No body composition data yet")
                .font(.caption.weight(.semibold))
            Text("If you use a smart scale that measures body fat or lean mass and syncs to Health, entries will appear here automatically.")
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
    BodyCompositionChartView(
        entries: (0..<12).map { i in
            BodyCompositionEntry(
                date: Calendar.current.date(byAdding: .weekOfYear, value: -i, to: .now) ?? .now,
                bodyFatPercent: 28 - Double(i) * 0.3,
                leanMassLbs: 120 + Double(i) * 0.2,
                source: .healthKit
            )
        }
    )
    .padding()
}
