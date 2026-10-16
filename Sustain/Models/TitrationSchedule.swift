import Foundation

/// One rung on a medication's standard dose-escalation ladder: the dose itself, and
/// how many weeks a patient conventionally stays at that dose before the next step
/// up (per each manufacturer's prescribing information / dosing guide). This is
/// reference data for *suggesting* a next step, not a substitute for what a
/// prescriber has actually told someone to do — `MedicationProfileEditView` only
/// ever pre-fills a suggestion the user can review and change, never applies one
/// automatically.
struct TitrationStep {
    let doseMg: Double
    let weeksAtThisDose: Int
}

/// Standard titration ladders for the medications `MedicationOption` already models.
/// Doses and intervals reflect each medication's typical prescribing-information
/// schedule, re-verified 2026-07-30 against each drug's current FDA-approved label
/// (Wegovy: `accessdata.fda.gov` label revised 02/2026; Zepbound, Ozempic, Mounjaro,
/// Rybelsus, Saxenda: current manufacturer prescribing information as of the same
/// date — see `Models/MedicalSource.swift`'s `.dosing` topic for the citation list).
/// A prescriber's actual plan for a given patient can and does differ (slower
/// titration for side-effect management is common), which is exactly why this only
/// ever *suggests* — see `MedicationProfileEditView.standardScheduleSuggestion`.
///
/// Keyed by (medication, form) rather than medication alone: Wegovy is the one
/// medication in this list with two FDA-approved delivery forms with genuinely
/// different dose ladders — the 02/2026-revised label added an oral tablet form
/// (1.5/4/9/25 mg, 30-day titration) alongside the pre-existing weekly injection
/// (0.25/0.5/1/1.7/2.4 mg). Before this, `MedicationProfileEditView`'s form picker
/// already let a user select "Wegovy" + "Oral pill" independently of this schedule
/// (the two pickers are unrelated `@State`), but this file only ever had Wegovy's
/// injection ladder — an oral-Wegovy user's real doses (e.g. 4 mg, 9 mg) simply
/// never matched a rung, so `nextStep` silently returned nil (a safe fallback, not
/// a wrong suggestion, but a missing one). This was flagged as an open risk in
/// `Documentation/APP_REVIEW_NOTES.md` §5 ("the Wegovy prescribing information now
/// also covers an oral tablet form... should be re-verified") before being
/// resolved here.
enum TitrationSchedule {
    private static let schedules: [MedicationOption: [MedicationForm: [TitrationStep]]] = [
        .wegovy: [
            .injection: [
                TitrationStep(doseMg: 0.25, weeksAtThisDose: 4),
                TitrationStep(doseMg: 0.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 1.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 1.7, weeksAtThisDose: 4),
                TitrationStep(doseMg: 2.4, weeksAtThisDose: 0),
            ],
            // Oral Wegovy tablets, added to the FDA label in 2026 alongside the
            // existing injection — titrates every 30 days, not weekly, same
            // 4-week-ladder-step convention used for Rybelsus below.
            .oralPill: [
                TitrationStep(doseMg: 1.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 4.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 9.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 25.0, weeksAtThisDose: 0),
            ],
        ],
        .ozempic: [
            .injection: [
                TitrationStep(doseMg: 0.25, weeksAtThisDose: 4),
                TitrationStep(doseMg: 0.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 1.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 2.0, weeksAtThisDose: 0),
            ],
        ],
        .zepbound: [
            .injection: [
                TitrationStep(doseMg: 2.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 5.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 7.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 10.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 12.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 15.0, weeksAtThisDose: 0),
            ],
        ],
        .mounjaro: [
            .injection: [
                TitrationStep(doseMg: 2.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 5.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 7.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 10.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 12.5, weeksAtThisDose: 4),
                TitrationStep(doseMg: 15.0, weeksAtThisDose: 0),
            ],
        ],
        .rybelsus: [
            // Rybelsus titrates on a 30-day, not weekly, cadence.
            .oralPill: [
                TitrationStep(doseMg: 3.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 7.0, weeksAtThisDose: 4),
                TitrationStep(doseMg: 14.0, weeksAtThisDose: 0),
            ],
        ],
        .saxenda: [
            // Saxenda steps up weekly, much faster than the semaglutide/tirzepatide
            // injectables above.
            .injection: [
                TitrationStep(doseMg: 0.6, weeksAtThisDose: 1),
                TitrationStep(doseMg: 1.2, weeksAtThisDose: 1),
                TitrationStep(doseMg: 1.8, weeksAtThisDose: 1),
                TitrationStep(doseMg: 2.4, weeksAtThisDose: 1),
                TitrationStep(doseMg: 3.0, weeksAtThisDose: 0),
            ],
        ],
        // `.compounded` and `.other` intentionally have no entry: compounded
        // formulations vary by pharmacy/prescriber with no single standard
        // schedule, and "Other" is unspecified by definition. Looking these up
        // returns nil, same as any unmatched dose below. Likewise, a form with no
        // real-world ladder for a given medication (e.g. "Ozempic" + "Oral pill",
        // a combination the form picker doesn't actually prevent someone from
        // selecting even though no such product exists) has no entry and safely
        // returns nil rather than guessing.
    ]

    /// The next standard step up from `currentDoseMg`, if `medication`+`form` has a
    /// known ladder and `currentDoseMg` matches one of its rungs closely enough to
    /// be confident which step the person is actually on (small manual-entry
    /// rounding aside — e.g. "1.7" vs "1.70"). Returns `nil` for an unrecognized
    /// medication/form combination, a dose that doesn't match any known rung, or
    /// the last rung on the ladder (nothing further to suggest).
    static func nextStep(for medication: MedicationOption, form: MedicationForm, currentDoseMg: Double) -> TitrationStep? {
        guard let ladder = schedules[medication]?[form],
              let currentIndex = ladder.firstIndex(where: { abs($0.doseMg - currentDoseMg) < 0.01 }),
              ladder.indices.contains(currentIndex + 1)
        else { return nil }
        return ladder[currentIndex + 1]
    }

    /// How many weeks to wait before the suggested change date — the *current*
    /// rung's `weeksAtThisDose`, i.e. how long someone conventionally stays on the
    /// dose they're on now before stepping up to what `nextStep` returns.
    static func weeksUntilNextStep(for medication: MedicationOption, form: MedicationForm, currentDoseMg: Double) -> Int? {
        guard let ladder = schedules[medication]?[form],
              let currentIndex = ladder.firstIndex(where: { abs($0.doseMg - currentDoseMg) < 0.01 }),
              ladder.indices.contains(currentIndex + 1)
        else { return nil }
        return ladder[currentIndex].weeksAtThisDose
    }
}
