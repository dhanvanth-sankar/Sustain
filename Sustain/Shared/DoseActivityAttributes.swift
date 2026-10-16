import ActivityKit
import Foundation

/// Shared between the main app (which starts/updates/ends the Live Activity,
/// see `Services/LiveActivityManager.swift`) and the `SustainWidgetExtension`
/// process, which only ever renders whatever `ContentState` the system hands
/// it — it never talks to SwiftData or RevenueCat directly.
///
/// This file is compiled into BOTH targets (see `project.yml`'s `sources` for
/// `SustainWidgetExtension`, which includes this `Shared/` folder) — ActivityKit
/// requires the exact same `ActivityAttributes` type to exist in both processes,
/// not just a structurally-identical copy.
struct DoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var nextDoseDate: Date
        var medicationName: String
        var doseMg: Double
        var proteinConsumedGrams: Double
        var proteinGoalGrams: Double
    }

    // No static (per-activity, unchanging) properties needed yet — everything
    // Sustain shows on the Lock Screen changes day to day, so it all lives in
    // `ContentState` above instead of here.
}
