import SwiftData
import SwiftUI

/// Added 2026-08-03, restructuring `LabResultsView`'s flat list: showing
/// every biomarker from every logged report inline made the list grow
/// unbounded and hard to scan as soon as someone had more than one or two
/// reports on file. Now `LabResultsView` shows one row per report date (a
/// submenu), and this is what that row pushes to — the full set of
/// biomarkers logged from one specific report.
///
/// Takes a day range rather than a captured array of `LabResultEntry`
/// objects, and runs its own `@Query`, matching the same pattern
/// `LabResultTrendView` already established (see that file's header comment
/// for the deleted-object crash this avoids): if a value is swiped away
/// while this screen is open, the query simply re-evaluates instead of this
/// view holding a stale reference to a deleted model.
struct LabResultDateDetailView: View {
    let dayStart: Date
    let dayEnd: Date
    let displayDate: Date

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [LabResultEntry]

    init(dayStart: Date, dayEnd: Date, displayDate: Date) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.displayDate = displayDate
        _entries = Query(
            filter: #Predicate<LabResultEntry> { $0.date >= dayStart && $0.date < dayEnd },
            sort: \LabResultEntry.biomarkerName
        )
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.biomarkerName)
                        Spacer()
                        Text("\(entry.value.formatted(.number.precision(.fractionLength(0...2)))) \(entry.unit)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        modelContext.delete(entries[index])
                    }
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle(displayDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Explicit Edit button, added specifically so delete is
            // discoverable — swipe-to-delete alone is easy to miss, and this
            // whole view exists because "there should definitely be a way to
            // delete lab results" was raised directly during manual testing.
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            MedicalSourcesLink(topic: .labResults, label: "How Sustain handles these values")
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }
}

#Preview {
    NavigationStack {
        LabResultDateDetailView(dayStart: .now, dayEnd: .now.addingTimeInterval(86400), displayDate: .now)
            .modelContainer(for: [LabResultEntry.self], inMemory: true)
    }
}
