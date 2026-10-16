import Foundation
import SwiftData

#if SCREENSHOT_MODE
/// Fabricates a complete, internally-consistent 10-week Wegovy journey so App
/// Store marketing screenshots show a realistic, compelling story instead of
/// whatever's left over from manual click-through testing.
///
/// This exists because manually logging test data by hand in the Simulator
/// kept producing screenshots with contradictions across cards — e.g. the
/// stats grid reading "Not enough weigh-ins" while the chart directly below
/// it showed a clean declining line, because the two were pulling from
/// differently-windowed manual entries. Generating the whole dataset in one
/// place, sized to the exact windows `ProgressCalculator` actually reads
/// (this week / previous week / the 21-day plateau window), guarantees every
/// card on screen is telling the same story.
///
/// "Realistic" is a deliberate constraint, not just "impressive" — a marketing
/// screenshot showing a 20lb weekly drop or a 175g/day protein average (both
/// things that showed up when this was seeded by hand) reads as fake and
/// undermines trust before someone's even opened the app. Every number below
/// is inside the range a real, adherent GLP-1 user could plausibly hit:
/// ~1.5lb/week average loss (well within typical/healthy 0.5-1% of body
/// weight per week), a protein average modestly above goal rather than
/// implausibly double it, and one dose logged per week matching the profile's
/// actual weekly frequency.
///
/// Entirely inert unless `SCREENSHOT_MODE` is manually added to Debug's
/// Active Compilation Conditions in Xcode Build Settings — same mechanism and
/// same "never defined for Release" guarantee as `EntitlementManager`'s
/// screenshot override, so this can never compile into an archived/App Store
/// build regardless. Removing the flag removes this file's entire contents
/// (everything below is wrapped in the same `#if`), leaving zero trace.
enum ScreenshotModeSeeder {
    /// Wipes any existing data and replaces it with the fabricated journey
    /// below. Runs unconditionally (not just "if empty") every launch under
    /// `SCREENSHOT_MODE`, so screenshots stay reproducible regardless of
    /// whatever a previous manual testing session left behind.
    static func seed(in context: ModelContext) {
        deleteAll(MedicationProfile.self, in: context)
        deleteAll(DoseLog.self, in: context)
        deleteAll(WeightEntry.self, in: context)
        deleteAll(ProteinEntry.self, in: context)
        deleteAll(SideEffectLog.self, in: context)
        deleteAll(BodyCompositionEntry.self, in: context)
        deleteAll(LabResultEntry.self, in: context)

        let now = Date.now
        let calendar = Calendar.current
        func date(daysAgo: Double) -> Date {
            calendar.date(byAdding: .second, value: -Int(daysAgo * 86400), to: now) ?? now
        }

        // MARK: Profile
        // Started 70 days ago at 214lb, aiming for 165lb — a real journey
        // still meaningfully in progress, not a finished, too-tidy story.
        let profile = MedicationProfile(
            medication: .wegovy,
            form: .injection,
            frequency: .weekly,
            startDate: date(daysAgo: 70),
            currentDoseMg: 1.7,
            startingWeightLbs: 214.0,
            targetWeightLbs: 165.0,
            hasStartedMedication: true
        )
        context.insert(profile)

        // MARK: Doses
        // Weekly cadence matching `frequency` above, dose ramped through a
        // realistic titration schedule, ending at the current 1.7mg. The
        // last entry (3 days ago) is the one that lands in "this week" for
        // the recap — exactly 1 taken, 0 skipped, matching a 1-dose weekly
        // expectation.
        let doseSchedule: [(daysAgo: Double, mg: Double)] = [
            (70, 0.25), (63, 0.25), (56, 0.25),
            (49, 0.5), (42, 0.5),
            (35, 1.0), (28, 1.0), (21, 1.0),
            (14, 1.7), (3, 1.7),
        ]
        for entry in doseSchedule {
            context.insert(DoseLog(date: date(daysAgo: entry.daysAgo), doseMg: entry.mg, form: .injection))
        }

        // MARK: Weight
        // Roughly weekly points from day 70 back to day 21 for a full chart
        // history, then two points each in the "previous week" (8-14 days
        // ago) and "this week" (0-6 days ago) windows so both
        // `weightChangeLbs` and `previousWeekWeightChangeLbs` are populated
        // with a real, modest, consistent decline (~1.2-1.4lb/week) rather
        // than nil or an implausible jump. Net change across the last 21
        // days (~4.5lb) is comfortably past the plateau-detection threshold,
        // so this reads as active, ongoing progress rather than a plateau.
        let weightSchedule: [(daysAgo: Double, lbs: Double)] = [
            (70, 214.0), (63, 211.7), (56, 209.6), (49, 207.8),
            (42, 206.2), (35, 204.8), (28, 203.6),
            (19, 202.5),
            (12, 201.4), (8, 200.2),
            (5, 199.4), (1, 198.0),
        ]
        for entry in weightSchedule {
            context.insert(WeightEntry(date: date(daysAgo: entry.daysAgo), weightLbs: entry.lbs))
        }

        // MARK: Protein
        // Daily entries for days 0-6 ("this week") and 8-14 ("previous
        // week"), deliberately skipping day 7 so the two windows don't
        // overlap and so the goal-streak calculation (which walks backward
        // day by day and stops at the first missed day) lands on a clean,
        // believable 7-day streak instead of an unbroken multi-week one.
        // Every value sits modestly above the ~132g goal (165lb target x
        // 0.8g/lb) rather than far above it.
        let thisWeekProtein: [Double] = [143, 138, 150, 145, 136, 148, 140] // days 0...6
        let previousWeekProtein: [Double] = [135, 144, 139, 151, 137, 146, 141] // days 8...14
        for (offset, grams) in thisWeekProtein.enumerated() {
            context.insert(ProteinEntry(date: date(daysAgo: Double(offset)), grams: grams))
        }
        for (offset, grams) in previousWeekProtein.enumerated() {
            context.insert(ProteinEntry(date: date(daysAgo: Double(offset + 8)), grams: grams))
        }

        // MARK: Body composition
        // `BodyCompositionChartView` (comp-priority-3's lite version) has
        // nothing seeded above to draw from, so it would render its own empty
        // state ("No body composition data yet") in a screenshot — a real gap
        // for a feature the report specifically flagged as visualizing "Lose
        // fat. Not muscle." directly instead of only implying it via protein
        // intake. Six roughly-biweekly entries across the same 70-day window
        // as the weight/dose data above, both fields present on every entry
        // (a real smart-scale sync, e.g. Withings/Renpho, reports both at
        // once — a manual/AI-photo-estimate flow is the one that'd plausibly
        // report only one field, and this is meant to look like the former).
        // Body fat % declines a realistic ~0.35 pts/week (18.5% -> 15.8%,
        // comfortably inside a healthy adult range throughout, never crash-
        // diet territory); lean mass barely moves (166.5lb -> 165.0lb, a 1.5lb
        // dip against a ~16lb total weight loss) — deliberately a much
        // smaller decline than the weight/fat trend, so the chart visibly
        // tells "the weight loss was fat, not muscle" rather than two
        // parallel declining lines that read as "everything just got
        // smaller."
        let bodyCompSchedule: [(daysAgo: Double, bodyFatPercent: Double, leanMassLbs: Double)] = [
            (63, 18.5, 166.5), (49, 17.9, 166.2), (35, 17.2, 165.9),
            (21, 16.6, 165.6), (12, 16.1, 165.3), (2, 15.8, 165.0),
        ]
        for entry in bodyCompSchedule {
            context.insert(BodyCompositionEntry(
                date: date(daysAgo: entry.daysAgo),
                bodyFatPercent: entry.bodyFatPercent,
                leanMassLbs: entry.leanMassLbs,
                source: .healthKit
            ))
        }

        // MARK: Lab results
        // `LabResultsView` needs at least 2 readings per biomarker before it
        // even lists that biomarker under its own "Trends" section (a
        // deliberate anti-dead-end-link rule — see that view's filter), so a
        // single seeded panel isn't enough to show that section or a real
        // trend chart. Two panels, 8 weeks apart, covering the metrics a
        // real GLP-1 patient's bloodwork panel would include and that
        // plausibly move with this journey's weight loss: lipids and glucose
        // control improve, everything stays within a normal reference range
        // throughout (this feature transcribes only, never flags a value —
        // see `LabResultEntry`'s header comment — so seeded values must never
        // require that judgment call to look "clean" in a screenshot).
        struct LabPanelEntry { let name: String; let value: Double; let unit: String }
        let earlierLabPanel: [LabPanelEntry] = [
            LabPanelEntry(name: "Fasting Glucose", value: 102, unit: "mg/dL"),
            LabPanelEntry(name: "Hemoglobin A1C", value: 5.9, unit: "%"),
            LabPanelEntry(name: "Total Cholesterol", value: 205, unit: "mg/dL"),
            LabPanelEntry(name: "LDL Cholesterol", value: 128, unit: "mg/dL"),
            LabPanelEntry(name: "HDL Cholesterol", value: 42, unit: "mg/dL"),
            LabPanelEntry(name: "Triglycerides", value: 168, unit: "mg/dL"),
            LabPanelEntry(name: "ALT", value: 34, unit: "U/L"),
        ]
        let recentLabPanel: [LabPanelEntry] = [
            LabPanelEntry(name: "Fasting Glucose", value: 93, unit: "mg/dL"),
            LabPanelEntry(name: "Hemoglobin A1C", value: 5.5, unit: "%"),
            LabPanelEntry(name: "Total Cholesterol", value: 182, unit: "mg/dL"),
            LabPanelEntry(name: "LDL Cholesterol", value: 104, unit: "mg/dL"),
            LabPanelEntry(name: "HDL Cholesterol", value: 47, unit: "mg/dL"),
            LabPanelEntry(name: "Triglycerides", value: 121, unit: "mg/dL"),
            LabPanelEntry(name: "ALT", value: 26, unit: "U/L"),
        ]
        for entry in earlierLabPanel {
            context.insert(LabResultEntry(date: date(daysAgo: 56), biomarkerName: entry.name, value: entry.value, unit: entry.unit))
        }
        for entry in recentLabPanel {
            context.insert(LabResultEntry(date: date(daysAgo: 4), biomarkerName: entry.name, value: entry.value, unit: entry.unit))
        }

        // MARK: Side effects
        // One mild, early entry for history-screen realism, well outside
        // both the current and previous week windows so it doesn't surface
        // in the weekly recap and muddy an otherwise clean current story.
        context.insert(SideEffectLog(date: date(daysAgo: 60), symptom: .nausea, severity: 2, notes: "Mild, first couple weeks"))

        try? context.save()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        guard let existing = try? context.fetch(FetchDescriptor<T>()) else { return }
        for object in existing {
            context.delete(object)
        }
    }
}
#endif
