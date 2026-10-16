import Charts
import SwiftUI

struct ProteinChartView: View {
    let entries: [ProteinEntry]
    let goalGrams: Double
    let windowDays: Int

    private struct DayTotal: Identifiable {
        let day: Date
        var total: Double
        var id: Date { day }
    }

    private var dailyTotals: [DayTotal] {
        let calendar = Calendar.current
        var totals: [Date: Double] = [:]
        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now)) else { continue }
            totals[day] = 0
        }
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            guard totals[day] != nil else { continue }
            totals[day, default: 0] += entry.grams
        }
        return totals.map { DayTotal(day: $0.key, total: $0.value) }.sorted { $0.day < $1.day }
    }

    // Derived from dailyTotals (already one O(n) pass over entries) instead of a second,
    // independent scan — the previous version called out to a helper that rescanned the
    // full entries array once per day in the window, i.e. O(windowDays × entries).
    private var adherence: Double {
        guard windowDays > 0 else { return 0 }
        let metDays = dailyTotals.filter { $0.total >= goalGrams }.count
        return Double(metDays) / Double(windowDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Protein, last \(windowDays) days")
                    .font(.headline)
                Spacer()
                Text("\(Int((adherence * 100).rounded()))% on target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(adherence >= 0.7 ? Theme.success : Theme.warning)
            }

            Chart {
                ForEach(dailyTotals) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Grams", day.total)
                    )
                    .foregroundStyle(day.total >= goalGrams ? Theme.success : Theme.primary)
                    .cornerRadius(4)
                    // `Theme.success` and `Theme.primary` are both teal/green family
                    // colors, so a goal-met bar was only distinguishable from a
                    // goal-missed one by hue — a real accessibility gap for
                    // color-blind users (PROJECT_HANDOFF §27, open question 2).
                    // Scoped narrowly to this chart's bar annotation rather than
                    // changing the shared `Theme.success` constant, which is used
                    // elsewhere as a general positive/success signal.
                    .annotation(position: .top) {
                        if day.total >= goalGrams {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.success)
                        }
                    }
                }

                RuleMark(y: .value("Goal", goalGrams))
                    .foregroundStyle(Theme.warning)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Goal \(Int(goalGrams))g")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(windowDays / 7, 1))) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 200)
        }
        .cardStyle()
    }
}

#Preview {
    ProteinChartView(
        entries: (0..<14).map { i in
            ProteinEntry(date: Calendar.current.date(byAdding: .day, value: -i, to: .now) ?? .now, grams: Double.random(in: 60...150))
        },
        goalGrams: 120,
        windowDays: 14
    )
    .padding()
}
