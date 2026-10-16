import Foundation
import SwiftData

/// Sleep, heart-rate variability (HRV), and resting heart rate, imported
/// read-only from HealthKit — the same "any wearable that already writes to
/// Health" pattern `BodyCompositionEntry` established for body fat/lean mass.
///
/// Added 2026-08-07 for `Sustain-Subscription-Payer-Features-Report-2026-08.md`
/// §4, the report's single highest-priority new finding: Oura shipped a
/// "GLP-1 Insights" feature correlating sleep/HRV against logged GLP-1
/// medication and side effects, on the clinical basis that GLP-1s can
/// disrupt sleep during titration and that HRV/resting heart rate are worth
/// watching during treatment. No GLP-1-*specific* tracker reviewed across
/// three research passes this project has done has this. Sustain doesn't
/// need to integrate with Oura, Whoop, or any single vendor's SDK to build
/// it — sleep analysis, HRV, and resting heart rate are all standard
/// HealthKit identifiers that any wearable (Apple Watch, Oura, Whoop,
/// Fitbit) already writes into the same shared Health store its own app
/// doesn't need to be running for Sustain to read.
///
/// All three fields are optional, same reasoning as `BodyCompositionEntry`:
/// a single HealthKit sync pass can have one metric and not another (e.g. an
/// Apple Watch writes HRV and resting heart rate every day but sleep only on
/// nights it's actually worn to bed), and forcing every field to be present
/// would silently drop real data rather than storing whatever's actually
/// there.
///
/// Deliberately **no computed "your side effects correlate with low
/// sleep/HRV" insight in this first version** — `RecoveryChartView` shows
/// the recovery trend with dose days marked so the user can look at both
/// together themselves, rather than the app asserting a statistical pattern
/// from what's realistically a small, noisy personal sample. The same
/// caution this app already holds itself to for the medication-level chart
/// and plateau messaging (real disclaimers, no overstated claims) applies
/// here even more directly, since correlation-from-small-n is an easy way to
/// mislead a well-meaning feature into something authoritative-sounding it
/// isn't.
@Model
final class RecoveryEntry {
    var id: UUID
    var date: Date
    var sleepHours: Double?
    var hrvMilliseconds: Double?
    var restingHeartRateBPM: Double?
    var sourceRaw: String

    init(
        date: Date = .now,
        sleepHours: Double? = nil,
        hrvMilliseconds: Double? = nil,
        restingHeartRateBPM: Double? = nil,
        source: EntrySource = .healthKit
    ) {
        self.id = UUID()
        self.date = date
        self.sleepHours = sleepHours
        self.hrvMilliseconds = hrvMilliseconds
        self.restingHeartRateBPM = restingHeartRateBPM
        self.sourceRaw = source.rawValue
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .healthKit }
        set { sourceRaw = newValue.rawValue }
    }
}
