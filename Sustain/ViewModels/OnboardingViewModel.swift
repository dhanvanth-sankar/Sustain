import Foundation
import Observation
import SwiftData

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case medication
    case dose
    case goals
    /// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §4a:
    /// the report's single highest-cited conversion lever is Noom's
    /// personalized "watch your program get built" moment right before its
    /// paywall — real inputs already collected during onboarding, assembled
    /// into something that reads as made specifically for this person,
    /// building investment before any ask for money appears. See
    /// `OnboardingProjectionView`'s header comment for why this deliberately
    /// does NOT copy Noom's literal mechanic (an animated projected-weight
    /// curve) — this app's own established Guideline 1.4.1 caution about
    /// presenting anything as a personalized health prediction rules that
    /// specific version out.
    case projection
}

@Observable
final class OnboardingViewModel {
    var step: OnboardingStep = .welcome

    // Defaults to the oral option (consistent with its own defaultForm/defaultFrequency
    // below) so the onboarding flow's first impression is oral-first, not
    // injection-first — a deliberate positioning choice, not an arbitrary default.
    // Any tap on a different medication in step 2 overrides all three immediately.
    var medication: MedicationOption = .rybelsus
    var form: MedicationForm = .oralPill
    var frequency: DoseFrequency = .daily
    /// Only meaningful when `frequency == .specificDays` — see
    /// `WeekdaySelector`'s doc comment.
    var scheduledWeekdays: Set<Int> = []
    var startDate: Date = .now
    var currentDoseMg: Double = 2.5

    /// Only meaningful when `medication == .custom` — see
    /// `MedicationProfile.customMedicationName`'s doc comment for the storage
    /// design this feeds. `customHalfLifeDays` is entered in days (what someone
    /// actually knows from a prescribing label) and converted to hours only at
    /// `OnboardingFlow.completeOnboarding()`'s write site, matching every other
    /// half-life value's underlying hours storage.
    var customMedicationName: String = ""
    var customHalfLifeDays: Double? = nil

    /// False only via `skipMedication()` — the "I haven't started yet" onboarding
    /// path. `medication`/`form`/`frequency`/`currentDoseMg` still hold whatever
    /// defaults or last selection was on screen, but they're not a real answer in
    /// that state, so `completeOnboarding()` and every dose-dependent feature must
    /// check this flag rather than assume those fields mean anything.
    var hasStartedMedication: Bool = true

    var weightUnit: WeightUnit = .pounds
    var startingWeightLbs: Double = 180
    var hasTargetWeight: Bool = false
    var targetWeightLbs: Double = 160

    var isRequestingPermissions = false

    // MARK: - Prefill from existing data (2026-07-31)

    /// Set by `prefill(from:latestWeight:)` when this device already has a
    /// `MedicationProfile` — someone who signed in and either already had
    /// local data or just pulled it down from the cloud. Onboarding runs for
    /// everyone regardless (see `OnboardingFlow`'s header comment for why
    /// that's now deliberate, not a gap), but when this is non-nil,
    /// `completeOnboarding()` updates this same profile in place instead of
    /// inserting a duplicate.
    var existingProfile: MedicationProfile?

    /// Whether each field below **had** real saved data to prefill from at
    /// all — used by `completeOnboarding()` to decide whether the
    /// starting-weight dedup check below is even relevant, and by the views
    /// as the base "is there anything to show a restore button for" check
    /// (via the `saved*Display` properties further down, which return `nil`
    /// when the corresponding flag here is `false`).
    var medicationWasPrefilled = false
    var doseWasPrefilled = false
    var weightWasPrefilled = false
    var targetWeightWasPrefilled = false

    /// The exact values that were prefilled, kept separately from the
    /// editable properties above.
    ///
    /// **History**: this snapshot was first added (2026-07-31) to back a
    /// passive "Saved value" note that compared the live field against it —
    /// a real bug ("it keeps saying saved value even though I'm changing it
    /// in real time") from an earlier version that only checked whether a
    /// field *had* been prefilled, not whether it still matched. That note
    /// was itself superseded the same week by an explicit request for
    /// something more useful: a per-field button that both shows the saved
    /// value and restores it on tap, rather than just a status label. The
    /// snapshot turned out to be exactly what a "restore" action needs
    /// anyway, so it stayed — see `saved*Display`/`restore*ToSaved()` below.
    private var prefilledMedication: MedicationOption?
    private var prefilledForm: MedicationForm?
    private var prefilledFrequency: DoseFrequency?
    private var prefilledScheduledWeekdays: Set<Int>?
    private var prefilledDoseMg: Double?
    private var prefilledStartingWeightLbs: Double?
    private var prefilledTargetWeightLbs: Double?

    /// Called once by `OnboardingFlow` right before showing step 1, with
    /// whatever this device already has on record. A device with no prior
    /// data (first-ever sign-in, brand-new account) passes `nil` for both
    /// and every field simply keeps its hardcoded default — this function is
    /// a no-op in that case, not a special path.
    func prefill(from profile: MedicationProfile?, latestWeight: WeightEntry?) {
        existingProfile = profile

        if let profile {
            medication = profile.medication
            form = profile.form
            frequency = profile.frequency
            scheduledWeekdays = profile.scheduledWeekdays
            hasStartedMedication = profile.hasStartedMedication
            customMedicationName = profile.customMedicationName ?? ""
            customHalfLifeDays = profile.customHalfLifeHours.map { $0 / 24 }
            medicationWasPrefilled = true
            prefilledMedication = profile.medication
            prefilledForm = profile.form
            prefilledFrequency = profile.frequency
            prefilledScheduledWeekdays = profile.scheduledWeekdays

            if profile.hasStartedMedication {
                currentDoseMg = profile.currentDoseMg
                startDate = profile.startDate
                doseWasPrefilled = true
                prefilledDoseMg = profile.currentDoseMg
            }

            if let targetWeightLbs = profile.targetWeightLbs {
                hasTargetWeight = true
                // `prefill` always runs before the user has touched the unit
                // picker (still its `.pounds` default), so this is a direct
                // assignment, not a conversion — `weightUnitBinding` in
                // `OnboardingGoalsView` handles converting both weight
                // fields together if the user switches units afterward.
                self.targetWeightLbs = targetWeightLbs
                targetWeightWasPrefilled = true
                prefilledTargetWeightLbs = targetWeightLbs
            }
        }

        // The profile's own `startingWeightLbs` is a point-in-time snapshot
        // from whenever it was created, not necessarily current — a real
        // logged `WeightEntry` (most recent one on this device) is a better
        // "what should this field show" answer when one exists, so it takes
        // priority over the profile's field of the same name.
        if let latestWeight {
            startingWeightLbs = latestWeight.weightLbs
            weightWasPrefilled = true
            prefilledStartingWeightLbs = latestWeight.weightLbs
        } else if let profile, let startingWeightLbs = profile.startingWeightLbs {
            self.startingWeightLbs = startingWeightLbs
            weightWasPrefilled = true
            prefilledStartingWeightLbs = startingWeightLbs
        }
    }

    /// Whether the on-screen weight field still matches the prefilled value
    /// (accounting for the current display unit) — used by
    /// `completeOnboarding()` to decide whether the user is confirming an
    /// existing weight (skip logging a duplicate `WeightEntry`) or entering
    /// a genuinely new reading.
    var startingWeightUnchangedFromPrefill: Bool {
        guard let prefilledStartingWeightLbs else { return false }
        return abs(poundsValue(startingWeightLbs) - prefilledStartingWeightLbs) < 0.05
    }

    // MARK: - "Saved: …" restore buttons

    /// Formatted saved-medication summary for `SavedValueButton`, or `nil`
    /// when there's nothing saved to show a button for.
    var savedMedicationDisplay: String? {
        guard medicationWasPrefilled,
              let prefilledMedication, let prefilledForm, let prefilledFrequency
        else { return nil }
        return "\(prefilledMedication.rawValue) · \(Self.frequencySummary(prefilledForm, prefilledFrequency, prefilledScheduledWeekdays))"
    }

    /// Copies the saved medication/form/frequency (and, for a specific-days
    /// schedule, which days) back into the editable fields — the action
    /// behind `OnboardingMedicationView`'s `SavedValueButton`.
    func restoreMedicationToSaved() {
        guard let prefilledMedication, let prefilledForm, let prefilledFrequency else { return }
        medication = prefilledMedication
        form = prefilledForm
        frequency = prefilledFrequency
        scheduledWeekdays = prefilledScheduledWeekdays ?? []
        hasStartedMedication = true
    }

    /// Real gap, reported directly: the medication picker's combined
    /// "Saved: ___" button up top already covers form/frequency (see
    /// `restoreMedicationToSaved()` above, which sets all three together),
    /// but the "Form & schedule" card further down — its own visually
    /// separate section — had no saved-value indicator of its own, unlike
    /// every other field on this screen (starting weight, target weight,
    /// dose amount), which each show one right next to the specific control
    /// they apply to. Added so a saved value is visible right where someone
    /// is actually looking, not just bundled into a note near a different
    /// control further up the screen.
    var savedFormFrequencyDisplay: String? {
        guard medicationWasPrefilled, let prefilledForm, let prefilledFrequency else { return nil }
        return Self.frequencySummary(prefilledForm, prefilledFrequency, prefilledScheduledWeekdays)
    }

    /// Restores just form/frequency (and scheduled days, if applicable),
    /// independent of medication — lets someone revert a form/schedule
    /// change without also reverting a medication change they meant to keep.
    func restoreFormFrequencyToSaved() {
        guard let prefilledForm, let prefilledFrequency else { return }
        form = prefilledForm
        frequency = prefilledFrequency
        scheduledWeekdays = prefilledScheduledWeekdays ?? []
    }

    /// Shared formatting for both "Saved: ___" displays above — spells out
    /// which days for a `.specificDays` schedule (e.g. "Injection · Specific
    /// days: Mon, Wed, Fri") rather than just "Specific days" on its own,
    /// since the days are the actually-useful part of that summary.
    private static func frequencySummary(_ form: MedicationForm, _ frequency: DoseFrequency, _ weekdays: Set<Int>?) -> String {
        guard frequency == .specificDays, let weekdays, !weekdays.isEmpty else {
            return "\(form.displayName) · \(frequency.displayName)"
        }
        let symbols = Calendar.current.shortWeekdaySymbols
        let dayNames = weekdays.sorted().compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
        return "\(form.displayName) · \(frequency.displayName): \(dayNames.joined(separator: ", "))"
    }

    var savedDoseDisplay: String? {
        guard doseWasPrefilled, let prefilledDoseMg else { return nil }
        return "\(prefilledDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg"
    }

    func restoreDoseToSaved() {
        guard let prefilledDoseMg else { return }
        currentDoseMg = prefilledDoseMg
        hasStartedMedication = true
    }

    /// Saved starting weight, formatted in whatever unit is currently
    /// selected on screen (`weightUnit`), not necessarily the unit it was
    /// originally saved in — `prefilledStartingWeightLbs` is always stored
    /// in pounds, same as every other weight value in this app.
    var savedStartingWeightDisplay: String? {
        guard weightWasPrefilled, let prefilledStartingWeightLbs else { return nil }
        let displayValue = WeightUnit.pounds.convert(prefilledStartingWeightLbs, to: weightUnit)
        return "\(displayValue.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation)"
    }

    func restoreStartingWeightToSaved() {
        guard let prefilledStartingWeightLbs else { return }
        startingWeightLbs = WeightUnit.pounds.convert(prefilledStartingWeightLbs, to: weightUnit)
    }

    var savedTargetWeightDisplay: String? {
        guard targetWeightWasPrefilled, let prefilledTargetWeightLbs else { return nil }
        let displayValue = WeightUnit.pounds.convert(prefilledTargetWeightLbs, to: weightUnit)
        return "\(displayValue.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation)"
    }

    func restoreTargetWeightToSaved() {
        guard let prefilledTargetWeightLbs else { return }
        targetWeightLbs = WeightUnit.pounds.convert(prefilledTargetWeightLbs, to: weightUnit)
    }

    var progress: Double {
        Double(step.rawValue) / Double(OnboardingStep.allCases.count - 1)
    }

    var canGoNext: Bool {
        switch step {
        case .welcome: return true
        case .medication:
            // A specific-days schedule with zero days actually selected
            // isn't a real answer — same reasoning as requiring a nonzero
            // dose below, just for this step instead.
            guard hasStartedMedication, frequency == .specificDays else { return true }
            return !scheduledWeekdays.isEmpty
        case .dose: return currentDoseMg > 0
        case .goals: return startingWeightLbs > 0
        case .projection: return true
        }
    }

    /// Same formula as `MedicationProfile.dailyProteinGoalGrams(fallbackWeightLbs:)`,
    /// duplicated deliberately rather than requiring a real `MedicationProfile`
    /// instance this view model doesn't have yet (the profile isn't created
    /// until `OnboardingFlow.completeOnboarding()` runs, after this step is
    /// already shown) — used by `OnboardingProjectionView` to preview the
    /// same protein goal the Dashboard will show from the very first day.
    var previewProteinGoalGrams: Double {
        // `startingWeightLbs`/`targetWeightLbs` are entered in whatever unit
        // `weightUnit` currently is, same as everywhere else on this screen —
        // `poundsValue(_:)` converts to real pounds before applying the
        // formula, which (like the profile's own version) always operates in
        // pounds regardless of display unit.
        let displayWeight = hasTargetWeight ? targetWeightLbs : startingWeightLbs
        let weight = poundsValue(displayWeight)
        guard weight > 0 else { return 100 }
        return (weight * 0.8).rounded()
    }

    var isLastStep: Bool { step == OnboardingStep.allCases.last }

    // The dose step (start date + current dose) only makes sense once someone has
    // actually started a medication — skip it entirely in both directions when
    // `hasStartedMedication` is false, rather than showing a step that asks for a
    // dose that doesn't exist yet.
    func goNext() {
        var nextRaw = step.rawValue + 1
        if !hasStartedMedication, OnboardingStep(rawValue: nextRaw) == .dose {
            nextRaw += 1
        }
        guard let next = OnboardingStep(rawValue: nextRaw) else { return }
        step = next
        // Growth-strategy item 1 (install → onboarding-complete rate, with a
        // step-level breakdown of where people drop off) — fired on forward
        // navigation only, not `goBack()`, so someone bouncing back and
        // forth between two steps doesn't inflate that step's reach count.
        AnalyticsManager.track(.onboardingStepReached(next))
    }

    func goBack() {
        var prevRaw = step.rawValue - 1
        if !hasStartedMedication, OnboardingStep(rawValue: prevRaw) == .dose {
            prevRaw -= 1
        }
        guard let prev = OnboardingStep(rawValue: prevRaw) else { return }
        step = prev
    }

    func selectMedication(_ option: MedicationOption) {
        medication = option
        form = option.defaultForm
        frequency = option.defaultFrequency
        hasStartedMedication = true
    }

    /// The "I haven't started yet" option on the medication screen — lets someone
    /// still considering treatment (or waiting on a prescription) through the rest
    /// of onboarding without forcing a medication/dose answer that isn't true yet.
    func skipMedication() {
        hasStartedMedication = false
    }

    /// Displayed weight converted to pounds for storage, since models are pounds-based internally.
    func poundsValue(_ displayValue: Double) -> Double {
        weightUnit.convert(displayValue, to: .pounds)
    }
}
