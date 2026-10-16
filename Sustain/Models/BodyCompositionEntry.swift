import Foundation
import SwiftData

/// The lite, buildable version of report priority #3
/// (`Sustain-Subscription-Conversion-Report-2026-08.md`, "AI body scan / body
/// composition visualization"). A real camera-based body scan needs a
/// third-party photogrammetry SDK — a vendor decision this session explicitly
/// did not make (see `Sustain-Remaining-Priorities-Scoping-2026-08.md`). This
/// model instead captures the same underlying metrics (body fat %, lean mass)
/// from HealthKit, which many users already populate via a smart scale
/// (Withings, Renpho, Eufy, etc.) — no camera, no vendor SDK, no new
/// permission beyond the HealthKit access Sustain already requests. It still
/// delivers the report's core point directly: a trend line that visualizes
/// "Lose fat. Not muscle." rather than only inferring it from protein intake.
///
/// Both fields are optional because a single HealthKit sample can report just
/// one metric (e.g. a scale that only measures body fat %, not lean mass) —
/// forcing both to be present per entry would silently drop real data.
@Model
final class BodyCompositionEntry {
    var id: UUID
    var date: Date
    var bodyFatPercent: Double?
    var leanMassLbs: Double?
    var sourceRaw: String

    init(
        date: Date = .now,
        bodyFatPercent: Double? = nil,
        leanMassLbs: Double? = nil,
        source: EntrySource = .manual
    ) {
        self.id = UUID()
        self.date = date
        self.bodyFatPercent = bodyFatPercent
        self.leanMassLbs = leanMassLbs
        self.sourceRaw = source.rawValue
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}
