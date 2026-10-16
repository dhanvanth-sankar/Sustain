import SwiftUI

/// The confirm-before-save step `LabResultExtractor`'s header comment
/// promises: nothing extracted from a photo is written to `LabResultEntry`
/// until the user has seen it laid out against the source report they still
/// have and explicitly saved it. Every field is editable, any row can be
/// removed, and the panel's test date is chosen here rather than assumed.
struct LabResultReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Date, [ExtractedBiomarker]) -> Void

    @State private var rows: [EditableRow]
    /// Caught in pre-test audit: the first version stamped every saved entry
    /// with `Date.now`, i.e. the *import* date, so importing a backlog of
    /// older reports collapsed them all onto today and made the trend chart
    /// meaningless. The date on a lab report is a real, printed value the
    /// user can read off the page in front of them, so it's asked for rather
    /// than inferred.
    ///
    /// Added 2026-08-03: this used to always default to today regardless of
    /// what the report actually said, requiring a manual change every time —
    /// raised directly during manual testing. `LabResultExtractor` now
    /// attempts to read the printed date off the photo itself; when it
    /// succeeds, that becomes the starting value here instead. Still fully
    /// editable either way — an extraction miss or a wrong read is a
    /// one-tap fix, never a silent error, same posture as every other
    /// extracted field on this screen.
    @State private var testDate: Date
    /// Drives the "read from your photo" caption below the date picker —
    /// purely informational, so the user knows to double-check an
    /// auto-filled date rather than assuming it's just today's date by
    /// default, same reasoning as every other extracted value on this
    /// screen being shown for confirmation, not silently trusted.
    private let wasDateExtracted: Bool

    private struct EditableRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var unit: String
    }

    init(biomarkers: [ExtractedBiomarker], initialTestDate: Date? = nil, onSave: @escaping (Date, [ExtractedBiomarker]) -> Void) {
        self.onSave = onSave
        _rows = State(initialValue: biomarkers.map {
            EditableRow(name: $0.name, value: Self.editableString(from: $0.value), unit: $0.unit)
        })
        // Clamped to `.now` defensively: the date picker below only allows
        // up to today (`in: ...Date.now`), and a misread date somehow
        // landing in the future would otherwise hand the picker an initial
        // value outside its own allowed range.
        _testDate = State(initialValue: min(initialTestDate ?? .now, .now))
        wasDateExtracted = initialTestDate != nil
    }

    /// Deliberately NOT `.formatted(.number...)`. Caught in pre-test audit:
    /// a localized string round-trips badly against `Double(_:)`, which is
    /// locale-invariant — a lab value of 1234 renders as "1,234" in en_US,
    /// `Double("1,234")` returns nil, and Save silently stays disabled with
    /// nothing on screen explaining why. Same failure in every
    /// comma-decimal locale. `%g` gives a plain, parseable representation
    /// that also drops trailing zeros ("98" not "98.00").
    private static func editableString(from value: Double) -> String {
        String(format: "%g", value)
    }

    private func parsedValue(_ text: String) -> Double? {
        // Accepts a comma decimal separator as well, since someone editing a
        // field by hand on a comma-decimal keyboard will reasonably type one.
        Double(text) ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        !rows.isEmpty && rows.allSatisfy { !$0.name.isEmpty && parsedValue($0.value) != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Check these against your report before saving. Sustain only transcribes the numbers, it never evaluates or interprets them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Test date") {
                    DatePicker("Date on the report", selection: $testDate, in: ...Date.now, displayedComponents: .date)
                    if wasDateExtracted {
                        Text("Read from your photo. Double-check it against the report.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // One Section wrapping a single ForEach, rather than a ForEach
                // emitting one Section per row. Caught in pre-test audit:
                // `.onDelete` attached to a ForEach that produces Sections
                // compiles but silently does nothing, so the "any row can be
                // removed" promise above was unfulfilled. Rows inside one
                // Section get real swipe-to-delete.
                Section("Values found") {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name", text: $row.name)
                                .font(.subheadline.weight(.medium))
                            HStack {
                                TextField("Value", text: $row.value)
                                    .keyboardType(.decimalPad)
                                TextField("Unit", text: $row.unit)
                                    .frame(width: 90)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        rows.remove(atOffsets: offsets)
                    }
                }

                if rows.isEmpty {
                    Section {
                        Text("No values left to save. Cancel and try another photo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Confirm values")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let confirmed = rows.compactMap { row -> ExtractedBiomarker? in
                            guard let value = parsedValue(row.value), !row.name.isEmpty else { return nil }
                            return ExtractedBiomarker(name: row.name, value: value, unit: row.unit)
                        }
                        onSave(testDate, confirmed)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
            .keyboardDoneButton()
        }
    }
}

#Preview {
    LabResultReviewView(biomarkers: [
        ExtractedBiomarker(name: "LDL", value: 98, unit: "mg/dL"),
        ExtractedBiomarker(name: "Vitamin D", value: 32, unit: "ng/mL"),
        ExtractedBiomarker(name: "Triglycerides", value: 1234, unit: "mg/dL"),
    ]) { _, _ in }
}
