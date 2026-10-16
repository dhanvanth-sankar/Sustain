import Charts
import SwiftUI

/// `entries` is expected pre-sorted descending by date — its one call site
/// (DashboardView) feeds it from `@Query(sort: \WeightEntry.date, order: .reverse)`,
/// so getting back to ascending for the chart is a cheap reversal, not a re-sort.
struct WeightTrendCard: View {
    let entries: [WeightEntry]
    let unit: WeightUnit
    let onLogWeight: () -> Void

    private var sorted: [WeightEntry] {
        Array(entries.reversed())
    }

    private var latest: WeightEntry? { sorted.last }

    private var change: Double? {
        ProgressCalculator.weightChange(entries)
    }

    private func displayValue(_ lbs: Double) -> Double {
        WeightUnit.pounds.convert(lbs, to: unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight")
                        .font(.subheadline.weight(.semibold))
                    if let latest {
                        Text("\(displayValue(latest.weightLbs).formatted(.number.precision(.fractionLength(0...1)))) \(unit.abbreviation)")
                            .font(.title2.bold())
                    } else {
                        Text("No entries yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let change {
                    changeBadge(change)
                }
            }

            if sorted.count >= 2 {
                Chart(sorted) { entry in
                    LineMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", displayValue(entry.weightLbs))
                    )
                    .foregroundStyle(Theme.primary)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", displayValue(entry.weightLbs))
                    )
                    .foregroundStyle(Theme.primaryLight)
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 70)
                // Purely decorative here (axes are already hidden) — the current
                // weight and change badge above already say the same thing in
                // words. Swift Charts' default accessibility behavior would
                // otherwise expose every data point individually, which is far
                // noisier for a VoiceOver user than the two lines of text they
                // already get from the rest of this card.
                .accessibilityHidden(true)
            }

            Button(action: onLogWeight) {
                Label("Log weight", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.primary)
            .controlSize(.small)
        }
        .cardStyle()
    }

    private func changeBadge(_ change: Double) -> some View {
        let displayChange = WeightUnit.pounds.convert(change, to: unit)
        let isLoss = displayChange < 0
        return Text("\(isLoss ? "" : "+")\(displayChange.formatted(.number.precision(.fractionLength(0...1)))) \(unit.abbreviation)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isLoss ? Theme.success.opacity(0.15) : Theme.warning.opacity(0.15))
            .foregroundStyle(isLoss ? Theme.success : Theme.warning)
            .clipShape(Capsule())
    }
}

#Preview {
    WeightTrendCard(
        entries: (0..<10).map { i in
            WeightEntry(date: Calendar.current.date(byAdding: .day, value: -i, to: .now) ?? .now, weightLbs: 200 - Double(i))
        },
        unit: .pounds,
        onLogWeight: {}
    )
    .padding()
}
