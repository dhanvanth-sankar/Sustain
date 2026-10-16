import SwiftData
import SwiftUI

struct LogWeightView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let weightUnit: WeightUnit

    @State private var date: Date = .now
    @State private var displayWeight: Double = 0
    @State private var syncToHealth = true

    // A scroll wheel has no natural "empty" state the way a `TextField` did
    // (`WeightWheelPicker`'s range starts at 50, never 0), so `canSave`
    // checking `displayWeight > 0` would otherwise be true from the very
    // first frame, before anyone's actually looked at the wheel — good
    // enough functionally, but it'd default to whatever the wheel's range
    // happens to start at rather than something meaningful to the person
    // logging it. Defaulting the wheel to their own last logged weight (see
    // `.task` below) instead means confirming without touching it is a
    // real, reasonable action ("still about the same"), not an accidental
    // save of an arbitrary number.
    private var canSave: Bool { displayWeight > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Date & time", selection: $date, in: ...Date.now)
                }

                Section("Weight") {
                    // Scroll wheel, not a typed number (explicit request) —
                    // see `WeightWheelPicker`'s doc comment.
                    WeightWheelPicker(weight: $displayWeight, unit: weightUnit)
                        .frame(maxWidth: .infinity)
                }

                Section {
                    Toggle("Sync to Apple Health", isOn: $syncToHealth)
                }
            }
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .keyboardDoneButton()
            .task {
                guard displayWeight == 0 else { return }
                var descriptor = FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
                descriptor.fetchLimit = 1
                if let latest = try? modelContext.fetch(descriptor).first {
                    displayWeight = WeightUnit.pounds.convert(latest.weightLbs, to: weightUnit)
                } else {
                    // No prior entries at all — a sensible mid-range
                    // starting point for the wheel, not a real logged value.
                    displayWeight = weightUnit == .pounds ? 180 : 82
                }
            }
        }
    }

    private func save() {
        let pounds = weightUnit.convert(displayWeight, to: .pounds)
        let entry = WeightEntry(date: date, weightLbs: pounds)
        modelContext.insert(entry)
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)

        if syncToHealth {
            Task {
                await HealthKitManager.shared.saveWeight(pounds: pounds, date: date)
            }
        }

        dismiss()
    }
}

#Preview {
    LogWeightView(weightUnit: .pounds)
        .modelContainer(for: [WeightEntry.self], inMemory: true)
}
