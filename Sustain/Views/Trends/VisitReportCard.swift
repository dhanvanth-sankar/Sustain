import SwiftUI

/// The "bring this to your appointment" card — one PDF combining medication/
/// dose history, weight trend, protein adherence, side effects, and lab
/// results. See `VisitReportPDFGenerator.swift`'s header comment for why this
/// exists as a separate, combined report rather than extending the older
/// side-effects-only `SideEffectReportPDFGenerator`/`SideEffectSummaryCard`,
/// which stays as its own quicker, single-topic share option.
///
/// Deliberately takes already-entitlement-filtered arrays (`TrendsView`'s own
/// `visible*` values, the same ones every other card on that screen already
/// receives) rather than querying its own unfiltered data — a free-tier user
/// exporting a report should see exactly the same history window the rest of
/// the screen already shows them, not a way to route around the 30-day
/// history gate through a PDF export.
struct VisitReportCard: View {
    let profile: MedicationProfile
    let doseLogs: [DoseLog]
    let weightEntries: [WeightEntry]
    let proteinEntries: [ProteinEntry]
    let proteinGoalGrams: Double
    let sideEffectLogs: [SideEffectLog]
    let labResults: [LabResultEntry]
    let weightUnit: WeightUnit

    private struct SymptomTally {
        let symptom: SideEffectSymptom
        let count: Int
        let averageSeverity: Double
    }

    private var symptomTallies: [SymptomTally] {
        Dictionary(grouping: sideEffectLogs, by: \.symptom)
            .map { symptom, entries in
                SymptomTally(
                    symptom: symptom,
                    count: entries.count,
                    averageSeverity: entries.reduce(0.0) { $0 + Double($1.severity) } / Double(entries.count)
                )
            }
            .sorted { $0.count > $1.count }
    }

    /// Same date-range logic as `SideEffectSummaryCard.dateRangeText`, but
    /// pooled across every data type this report covers rather than just
    /// one — the earliest/latest entry across doses, weight, protein, side
    /// effects, and labs together, so the printed period actually reflects
    /// everything in the document, not just one section of it.
    private var dateRangeText: String? {
        let allDates = doseLogs.map(\.date) + weightEntries.map(\.date) + proteinEntries.map(\.date)
            + sideEffectLogs.map(\.date) + labResults.map(\.date)
        guard let earliest = allDates.min(), let latest = allDates.max() else { return nil }
        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            return earliest.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return "\(earliest.formatted(.dateTime.month(.abbreviated).day())) – \(latest.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private var doseRows: [VisitReportPDFGenerator.TextRow] {
        // Newest-first, matching every other list in the app (Trends' own
        // dose-history section, the Watch rotation caption) rather than
        // introducing a new chronological convention just for this report.
        doseLogs.sorted { $0.date > $1.date }.map { log in
            let status = log.skipped ? "Skipped" : "\(log.doseMg.formatted(.number.precision(.fractionLength(0...2)))) mg"
            return VisitReportPDFGenerator.TextRow(
                leading: log.date.formatted(.dateTime.month(.abbreviated).day().year()),
                trailing: status
            )
        }
    }

    private var weightRows: [VisitReportPDFGenerator.TextRow] {
        weightEntries.sorted { $0.date > $1.date }.map { entry in
            let displayValue = WeightUnit.pounds.convert(entry.weightLbs, to: weightUnit)
            return VisitReportPDFGenerator.TextRow(
                leading: entry.date.formatted(.dateTime.month(.abbreviated).day().year()),
                trailing: "\(displayValue.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation)"
            )
        }
    }

    /// A short summary rather than every single logged entry — a daily
    /// protein log over months of history would dwarf every other section
    /// and isn't what a prescriber visit actually needs; the pattern (how
    /// consistently the goal was met) is more useful than the full ledger,
    /// which is still visible in-app if anyone wants it.
    private var proteinSummaryRows: [VisitReportPDFGenerator.TextRow] {
        guard !proteinEntries.isEmpty else { return [] }
        let byDay = Dictionary(grouping: proteinEntries) { Calendar.current.startOfDay(for: $0.date) }
        let daysLogged = byDay.count
        let daysMetGoal = byDay.values.filter { $0.reduce(0.0) { $0 + $1.grams } >= proteinGoalGrams }.count
        let averageGrams = proteinEntries.reduce(0.0) { $0 + $1.grams } / Double(proteinEntries.count)
        return [
            VisitReportPDFGenerator.TextRow(leading: "Daily goal", trailing: "\(Int(proteinGoalGrams.rounded()))g"),
            VisitReportPDFGenerator.TextRow(leading: "Days goal met", trailing: "\(daysMetGoal) of \(daysLogged) logged days"),
            VisitReportPDFGenerator.TextRow(leading: "Average per entry", trailing: "\(Int(averageGrams.rounded()))g"),
        ]
    }

    private var labRows: [VisitReportPDFGenerator.TextRow] {
        labResults.sorted { $0.date > $1.date }.map { result in
            VisitReportPDFGenerator.TextRow(
                leading: "\(result.date.formatted(.dateTime.month(.abbreviated).day().year())) — \(result.biomarkerName)",
                trailing: "\(result.value.formatted(.number.precision(.fractionLength(0...2)))) \(result.unit)"
            )
        }
    }

    private var pdfFileURL: URL? {
        VisitReportPDFGenerator.generateTemporaryFile(
            profileSummary: .init(
                leading: "\(profile.displayMedicationName) · \(profile.currentDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg · \(profile.frequency.displayName)",
                trailing: ""
            ),
            dateRangeText: dateRangeText,
            doseRows: doseRows,
            weightRows: weightRows,
            proteinSummaryRows: proteinSummaryRows,
            symptomRows: symptomTallies.map {
                VisitReportPDFGenerator.SymptomRow(displayName: $0.symptom.displayName, count: $0.count, averageSeverity: $0.averageSeverity)
            },
            labRows: labRows,
            disclaimer: MedicalSources.disclaimer
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundStyle(Theme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Visit report")
                    .font(.subheadline.weight(.semibold))
                Text("One PDF with your doses, weight, protein, side effects, and labs, ready to share with your prescriber.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let pdfFileURL {
                ShareLink(item: pdfFileURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(Theme.primary)
                }
                .accessibilityLabel("Share visit report as PDF")
            }
        }
        .cardStyle()
    }
}

#Preview {
    VisitReportCard(
        profile: MedicationProfile(
            medication: .zepbound,
            form: .injection,
            frequency: .weekly,
            startDate: .now,
            currentDoseMg: 5
        ),
        doseLogs: [DoseLog(date: .now, doseMg: 5, form: .injection)],
        weightEntries: [WeightEntry(date: .now, weightLbs: 190)],
        proteinEntries: [ProteinEntry(date: .now, grams: 110)],
        proteinGoalGrams: 130,
        sideEffectLogs: [SideEffectLog(symptom: .nausea, severity: 2)],
        labResults: [],
        weightUnit: .pounds
    )
    .padding()
}
