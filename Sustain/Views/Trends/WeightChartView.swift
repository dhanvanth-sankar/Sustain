import Charts
import SwiftUI

/// `entries` is expected pre-sorted ascending by date — its one call site
/// (TrendsView) feeds it straight from `@Query(sort: \WeightEntry.date)`, which is
/// already ascending by default, so re-sorting here would just repeat work the
/// query already did.
struct WeightChartView: View {
    let entries: [WeightEntry]
    let unit: WeightUnit

    private func displayValue(_ lbs: Double) -> Double {
        WeightUnit.pounds.convert(lbs, to: unit)
    }

    /// Exactly 4 explicit, evenly-spaced dates between the first and last entry,
    /// rather than asking Swift Charts to pick a count itself. Tried both
    /// `.stride(by: .weekOfYear)` (one label per week, overlapping/truncating
    /// past a few weeks of history) and `.automatic(desiredCount: 4)` (a hint
    /// Swift Charts doesn't reliably honor — it still produced 6 overlapping
    /// labels on some real date ranges, e.g. "Jul 5, J..." cut off). Computing
    /// the tick dates ourselves and passing them directly to `AxisMarks(values:)`
    /// removes the guesswork entirely: it's always exactly 4 labels, regardless
    /// of how many entries exist or how wide a span they cover.
    private var xAxisTickDates: [Date] {
        guard let first = entries.first?.date, let last = entries.last?.date, last > first else {
            return entries.map(\.date)
        }
        let tickCount = 4
        let interval = last.timeIntervalSince(first) / Double(tickCount - 1)
        return (0..<tickCount).map { first.addingTimeInterval(interval * Double($0)) }
    }

    /// The 4th tick above always lands exactly on the last data point (by
    /// construction), which put its label right at the plot area's edge —
    /// Swift Charts clips an overflowing label rather than letting it render
    /// past the frame. A first attempt at ~6% padding on both sides reduced
    /// that from "missing entirely" to "renders as a truncated ellipsis,"
    /// confirmed on a real screenshot — still not enough room. The leading
    /// label was never the problem (it renders fine flush against the left
    /// edge, since a left-anchored label naturally has room to extend
    /// rightward), so padding is now asymmetric: a small nudge on the left,
    /// a much larger one on the right, sized for a short abbreviated date
    /// string like "Jul 23" to fully fit past the last data point.
    private var xAxisDomain: ClosedRange<Date> {
        guard let first = entries.first?.date, let last = entries.last?.date, last > first else {
            let now = Date.now
            return now...now.addingTimeInterval(1)
        }
        let span = last.timeIntervalSince(first)
        let leadingPadding = span * 0.02
        let trailingPadding = span * 0.18
        return first.addingTimeInterval(-leadingPadding)...last.addingTimeInterval(trailingPadding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weight over time")
                .font(.headline)

            if entries.count >= 2 {
                Chart(entries) { entry in
                    LineMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", displayValue(entry.weightLbs))
                    )
                    .foregroundStyle(Theme.primary)
                    .interpolationMethod(.catmullRom)
                    .symbol(.circle)

                    AreaMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", displayValue(entry.weightLbs))
                    )
                    .foregroundStyle(Theme.primaryLight)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis {
                    AxisMarks(values: xAxisTickDates) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartXScale(domain: xAxisDomain)
                .frame(height: 220)
            } else {
                emptyState
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Log at least two weigh-ins to see your trend")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

#Preview {
    WeightChartView(
        entries: (0..<20).map { i in
            WeightEntry(date: Calendar.current.date(byAdding: .day, value: -i, to: .now) ?? .now, weightLbs: 200 - Double(i) * 0.6)
        },
        unit: .pounds
    )
    .padding()
}
