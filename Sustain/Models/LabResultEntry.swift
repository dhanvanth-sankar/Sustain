import Foundation
import SwiftData

/// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §6: several
/// apps (Oura's Lab Uploads, BloodTrends, Health3, Carrot Care) now let users
/// photograph or upload a lab report and get the biomarkers extracted and
/// trended automatically. Flagged in that report as the lowest-priority,
/// least-differentiated item — it isn't GLP-1-specific — but still real and
/// buildable, not impossible, so it's included rather than skipped outright.
///
/// **This is deliberately a transcription tool, never an interpretation
/// one.** One row is one biomarker reading from one test date: a name, a
/// number, a unit, nothing else. There is no "normal range," no
/// high/low/flag, no classification of any kind stored or shown anywhere in
/// this feature — see `LabResultExtractor`'s header comment for why that line
/// is held even more strictly here than elsewhere in the app: a
/// mis-transcribed dosing half-life has a citation and a caveat sitting next
/// to it; a mis-transcribed or (worse) auto-interpreted lab value has neither
/// and touches genuinely diagnostic-adjacent territory this app has never
/// gone near. Sustain reads the numbers off the page the user already has;
/// it never tells them what those numbers mean.
@Model
final class LabResultEntry {
    var id: UUID
    var date: Date
    var biomarkerName: String
    var value: Double
    var unit: String

    init(date: Date = .now, biomarkerName: String, value: Double, unit: String) {
        self.id = UUID()
        self.date = date
        self.biomarkerName = biomarkerName
        self.value = value
        self.unit = unit
    }
}

/// Added 2026-08-03: shared between `AIChatCoachService` and
/// `WeeklySummaryGenerator`, the two features that feed a user's own data to
/// an LLM. Kept here, next to the model itself, rather than duplicated in
/// each — the whole point of this type's transcription-only design (see the
/// header comment above) is that it's held consistently everywhere the data
/// travels; two independent copies of "how do we describe this to a model"
/// and "how do we check the model didn't interpret it anyway" is exactly how
/// that consistency would eventually drift.
extension LabResultEntry {
    /// Plain-text rendering for an AI prompt: name, value, unit, date, one
    /// per line, most recent first. Capped at `limit` entries so a long
    /// history doesn't grow a prompt unboundedly.
    static func promptSummary(for entries: [LabResultEntry], limit: Int = 30) -> String {
        entries
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { entry in
                "- \(entry.biomarkerName): \(String(format: "%g", entry.value)) \(entry.unit) (\(entry.date.formatted(date: .abbreviated, time: .omitted)))"
            }
            .joined(separator: "\n")
    }

    /// A hard, non-model-dependent safety net: catches language that
    /// *interprets* a lab value (high/low/normal/abnormal, a reference-range
    /// comparison) rather than simply stating it. Deliberately simple pattern
    /// matching, same posture as `AIChatCoachService.containsRiskyContent`'s
    /// dose-amount check — the goal is to catch the clearest failure mode
    /// cheaply, not to fully validate compliance in code. The system
    /// prompt's ground rules remain the primary defense; this is the
    /// backstop for when a model doesn't hold the line despite them.
    static func containsInterpretationLanguage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let phrases = [
            "is high", "is low", "is elevated", "is abnormal", "is normal",
            "within normal", "within the normal range", "outside the normal range",
            "reference range", "too high", "too low", "borderline high", "borderline low",
            "this indicates", "this suggests you have", "consistent with", "a sign of",
        ]
        return phrases.contains { lowered.contains($0) }
    }
}
