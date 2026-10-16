import Charts
import SwiftData
import SwiftUI

/// One biomarker's values over time — deliberately the plainest possible
/// chart in this app: a visible y-axis with real units (unlike the
/// medication-level chart, there's no reason to hide this axis, since a lab
/// value is a real, printed number, not a derived estimate) and nothing
/// else drawn on it. No reference range, no color-coded zones, no "normal"
/// band — see `LabResultEntry`'s header comment for why this feature holds
/// that line more strictly than anywhere else in the app.
///
/// Takes only a biomarker *name* and runs its own `@Query`, rather than
/// receiving a pre-filtered array of live `LabResultEntry` objects. Caught
/// in pre-test audit: an array captured when the NavigationLink destination
/// was built holds references that can be deleted out from under this view
/// (the parent list has swipe-to-delete), and reading a property on a
/// deleted `PersistentModel` traps at runtime. A `@Query` re-evaluates
/// against the live store instead, so a deletion just removes the row.
struct LabResultTrendView: View {
    let biomarkerName: String

    @Query private var entries: [LabResultEntry]

    init(biomarkerName: String) {
        self.biomarkerName = biomarkerName
        let name = biomarkerName
        _entries = Query(
            filter: #Predicate<LabResultEntry> { $0.biomarkerName == name },
            sort: \LabResultEntry.date
        )
    }

    private var sortedEntries: [LabResultEntry] { entries }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sortedEntries.count >= 2 {
                    Chart(sortedEntries) { entry in
                        LineMark(
                            x: .value("Date", entry.date),
                            y: .value("Value", entry.value)
                        )
                        .foregroundStyle(Theme.primary)
                        .interpolationMethod(.catmullRom)
                        .symbol(.circle)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 220)
                    .padding()
                    .cardStyle()
                } else {
                    Text("Add another lab report with this value to see a trend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sortedEntries.reversed()) { entry in
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(entry.value.formatted(.number.precision(.fractionLength(0...2)))) \(entry.unit)")
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sustain only shows the values from your reports over time. It never flags a value as high, low, or normal, that's a conversation for your prescriber.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    MedicalSourcesLink(topic: .labResults, label: "How Sustain handles these values")
                }
            }
            .padding()
        }
        // Real bug, found reviewing 2.1 screenshots: this screen's date/value
        // list is already wrapped in `.cardStyle()` (a white
        // `Theme.cardBackground` card), but unlike every other card-based
        // screen in the app (`DashboardView`, `TrendsView`,
        // `MaintenanceGuideView`, `PaywallView`, ...) this `ScrollView` never
        // sets `Theme.screenBackground` behind it. `Theme.cardBackground` is
        // `.secondarySystemGroupedBackground`, which is plain white in light
        // mode, identical to the view's own default background, so the card
        // had no visible edge at all: the dates and values looked like
        // floating text with nothing behind them, exactly the same root
        // cause as the once-invisible `ChatCoachView` assistant bubble.
        // Adding the same `Theme.screenBackground` every sibling screen
        // already uses gives the white card a visible light-gray screen to
        // sit on, same as everywhere else.
        .background(Theme.screenBackground)
        .navigationTitle(biomarkerName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        LabResultTrendView(biomarkerName: "LDL")
            .modelContainer(for: [LabResultEntry.self], inMemory: true)
    }
}
