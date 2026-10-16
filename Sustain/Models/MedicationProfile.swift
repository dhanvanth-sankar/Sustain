import Foundation
import SwiftData

/// The user's active medication plan. In v1 there is exactly one active profile at a time;
/// the model is still its own entity so multi-medication history is a non-breaking future add.
@Model
final class MedicationProfile {
    var id: UUID
    var medicationRaw: String
    var formRaw: String
    var frequencyRaw: String
    var startDate: Date
    var currentDoseMg: Double
    var startingWeightLbs: Double?
    var targetWeightLbs: Double?
    var isActive: Bool
    var createdAt: Date

    /// The prescriber's next scheduled dose step-up, if one has been entered — the
    /// report's "titration schedule" item. Previously the app only ever stored the
    /// *current* dose, so once a user's prescriber told them "go to 1mg in 4 weeks,"
    /// there was nowhere in the app to record that plan or be reminded when it
    /// arrived; the change just had to be remembered and applied manually. Both
    /// fields are set together and cleared together — see `hasPendingTitration`.
    var plannedNextDoseMg: Double?
    var plannedDoseChangeDate: Date?

    /// Whether this person has actually started taking a medication yet. Onboarding
    /// used to force everyone through medication/dose selection with no way out —
    /// someone still considering treatment (or waiting on a prescription) had no path
    /// through the app at all. `true` for every profile created the normal way; `false`
    /// only for the "I haven't started yet" onboarding path, where `medication`/`form`/
    /// `frequency`/`currentDoseMg` are just placeholder defaults, not a real answer, and
    /// every dose-dependent feature (reminders, titration, injection-site rotation)
    /// should stay hidden until this flips to `true` — which happens automatically the
    /// first time `MedicationProfileEditView` is saved (see its `save()`).
    ///
    /// The `= true` here is required, not just documentation — SwiftData's automatic
    /// lightweight migration needs a default on the stored property declaration itself
    /// to backfill existing persisted records when a new property is added. The
    /// `init` parameter default below doesn't count for migration purposes: any
    /// simulator or device with data from before this property existed fails to open
    /// its store on the next launch without this (`Code=134110 "An error occurred
    /// during persistent store migration"`, which is what got caught live during a
    /// manual click-through — the Dashboard hung forever on "Loading your plan…"
    /// because the model container never finished loading).
    var hasStartedMedication: Bool = true

    /// When this profile's fields were last actually changed — bumped at every
    /// mutation site (`MedicationProfileEditView.save()`, `OnboardingFlow
    /// .completeOnboarding()`'s update-in-place branch, and
    /// `applyPlannedTitration()` below). Added 2026-08-01 specifically to fix a
    /// disclosed two-device sync gap: `MedicationProfile` is the one record type
    /// sync doesn't treat as append-only (there's exactly one active profile per
    /// account), so without something to compare, whichever device's edit
    /// happened to *push* last would silently win, even if it was actually the
    /// older edit — e.g. an offline device reconnecting could clobber a newer
    /// edit made elsewhere in the meantime. `CloudSyncManager` now compares this
    /// timestamp on both push and pull and keeps whichever side is actually
    /// newer. See `CloudSyncManager.pushLocalData`'s doc comment for the full
    /// mechanism.
    ///
    /// `= Date()` here (not just in `init`) is required for the same SwiftData
    /// lightweight-migration reason as `hasStartedMedication` above — a stored
    /// property default lets existing on-device records backfill this field
    /// automatically instead of failing to open the store on next launch.
    var updatedAt: Date = Date()

    /// Backing storage for `.specificDays` schedules — a comma-joined list of
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday, matching
    /// `Calendar.component(.weekday, from:)` directly so `DoseFrequency
    /// .nextDueDate(after:scheduledWeekdays:)` needs no conversion). Only
    /// meaningful when `frequency == .specificDays`; ignored otherwise. A
    /// plain comma-joined `String`, not a separate SwiftData relationship or
    /// `[Int]` — this app already stores every other enum-backed field as a
    /// raw `String` for the same lightweight-migration-friendliness (see
    /// `medicationRaw`/`formRaw`/`frequencyRaw` above), and seven small
    /// integers don't need anything more structured than that.
    ///
    /// `= ""` here (not just in `init`) is required for the same SwiftData
    /// lightweight-migration reason as `hasStartedMedication`/`updatedAt`
    /// above — existing on-device records from before this property existed
    /// need a property-level default to backfill correctly.
    var scheduledWeekdaysRaw: String = ""

    /// Only meaningful when `medication == .custom` (comp-010 in
    /// `sustain-pros-and-cons.json`, matching Pokii's most-requested feature: a
    /// fully custom medication, not just a fixed built-in list). `nil`/empty for
    /// every other case. Stored as two separate optional fields rather than
    /// extending `MedicationOption` itself with an associated value, since a
    /// `String`-backed enum with an associated value can no longer
    /// auto-synthesize `CaseIterable`/`Codable` the way every other case here
    /// depends on — keeping the enum itself fixed-case and putting the free-form
    /// data on the profile (the same pattern `scheduledWeekdaysRaw` above
    /// already uses for per-profile data that doesn't belong on a fixed enum)
    /// avoids touching that.
    ///
    /// `= nil` on both here (not just in `init`) for the same SwiftData
    /// lightweight-migration reason as `hasStartedMedication`/`updatedAt` above.
    var customMedicationName: String? = nil
    var customHalfLifeHours: Double? = nil

    /// Added 2026-09-27 from `Sustain-GLP1-Market-PESTLE-FeatureGap-Report-2026-09.md`'s
    /// #1 finding: roughly three in four GLP-1 patients discontinue within two years,
    /// overwhelmingly for cost/insurance reasons rather than the medication stopping
    /// working, and no reviewed competitor (including this app, until now) treats "I
    /// stopped" as anything other than churn. Every dose-dependent feature this app
    /// already has — `hasStartedMedication` gates them on the way in, this gates them
    /// on the way out. Deliberately reversible (`resumeMedication()` below), not a
    /// one-way flag: someone restarting later shouldn't have to re-add their whole
    /// medication plan from scratch.
    ///
    /// `= false` here (not just in `init`) for the same SwiftData lightweight-migration
    /// reason every other property added after the model's original shape documents
    /// above (`hasStartedMedication`, `updatedAt`, `scheduledWeekdaysRaw`) — existing
    /// on-device records need a stored-property default to backfill without failing to
    /// open the store on next launch.
    var isDiscontinued: Bool = false
    var discontinuedDate: Date? = nil
    /// See `DiscontinuationReason`'s own doc comment for why this is optional, never
    /// sent to analytics, and stored as a raw string for the same lightweight-migration
    /// friendliness every other enum-backed field on this model already uses.
    var discontinuedReasonRaw: String? = nil

    init(
        medication: MedicationOption,
        form: MedicationForm,
        frequency: DoseFrequency,
        startDate: Date,
        currentDoseMg: Double,
        startingWeightLbs: Double? = nil,
        targetWeightLbs: Double? = nil,
        plannedNextDoseMg: Double? = nil,
        plannedDoseChangeDate: Date? = nil,
        hasStartedMedication: Bool = true,
        updatedAt: Date = Date(),
        scheduledWeekdays: Set<Int> = [],
        customMedicationName: String? = nil,
        customHalfLifeHours: Double? = nil
    ) {
        self.id = UUID()
        self.medicationRaw = medication.rawValue
        self.formRaw = form.rawValue
        self.frequencyRaw = frequency.rawValue
        self.startDate = startDate
        self.currentDoseMg = currentDoseMg
        self.startingWeightLbs = startingWeightLbs
        self.targetWeightLbs = targetWeightLbs
        self.plannedNextDoseMg = plannedNextDoseMg
        self.plannedDoseChangeDate = plannedDoseChangeDate
        self.hasStartedMedication = hasStartedMedication
        self.isActive = true
        self.createdAt = Date()
        self.updatedAt = updatedAt
        self.scheduledWeekdaysRaw = Self.encodeWeekdays(scheduledWeekdays)
        self.customMedicationName = customMedicationName
        self.customHalfLifeHours = customHalfLifeHours
    }

    var medication: MedicationOption {
        get { MedicationOption(rawValue: medicationRaw) ?? .other }
        set { medicationRaw = newValue.rawValue }
    }

    /// What every user-facing screen should actually display — `medication.rawValue`
    /// for every fixed case, or the user's own entered name for `.custom` (falling
    /// back to the enum's own "Custom" label if someone somehow reaches `.custom`
    /// with no name entered, which the edit/onboarding UI shouldn't normally allow).
    var displayMedicationName: String {
        guard medication == .custom, let customMedicationName, !customMedicationName.isEmpty else {
            return medication.rawValue
        }
        return customMedicationName
    }

    /// What `MedicationLevelCalculator`/`MedicationLevelCard` should actually use —
    /// `medication.eliminationHalfLifeHours` for every fixed case (already `nil` for
    /// `.custom` by construction, see that property's doc comment), or this
    /// profile's own entered value for `.custom`.
    var effectiveHalfLifeHours: Double? {
        medication == .custom ? customHalfLifeHours : medication.eliminationHalfLifeHours
    }

    var form: MedicationForm {
        get { MedicationForm(rawValue: formRaw) ?? .injection }
        set { formRaw = newValue.rawValue }
    }

    var frequency: DoseFrequency {
        get { DoseFrequency(rawValue: frequencyRaw) ?? .weekly }
        set { frequencyRaw = newValue.rawValue }
    }

    /// Parsed view of `scheduledWeekdaysRaw` — see that property's doc
    /// comment for the storage format and why it's a raw string underneath.
    var scheduledWeekdays: Set<Int> {
        get { Set(scheduledWeekdaysRaw.split(separator: ",").compactMap { Int($0) }) }
        set { scheduledWeekdaysRaw = Self.encodeWeekdays(newValue) }
    }

    private static func encodeWeekdays(_ days: Set<Int>) -> String {
        days.sorted().map(String.init).joined(separator: ",")
    }

    /// Recommended daily protein target using the widely cited muscle-preservation
    /// guidance of ~0.7-1.0g of protein per pound of goal body weight, defaulting to
    /// 0.8g/lb when no target weight has been set yet.
    func dailyProteinGoalGrams(fallbackWeightLbs: Double) -> Double {
        let weight = targetWeightLbs ?? startingWeightLbs ?? fallbackWeightLbs
        guard weight > 0 else { return 100 }
        return (weight * 0.8).rounded()
    }

    var hasPendingTitration: Bool {
        plannedNextDoseMg != nil && plannedDoseChangeDate != nil
    }

    /// Whether the planned change date has arrived — flips the Dashboard's titration
    /// card from "counting down" into an actionable "apply now" state.
    var isTitrationDue: Bool {
        guard let date = plannedDoseChangeDate else { return false }
        return date <= .now
    }

    /// Commits the planned dose to `currentDoseMg` and clears the plan. Callers are
    /// also expected to cancel the titration reminder notification, since there's
    /// nothing left to remind about once this runs.
    func applyPlannedTitration() {
        guard let nextDose = plannedNextDoseMg else { return }
        currentDoseMg = nextDose
        plannedNextDoseMg = nil
        plannedDoseChangeDate = nil
        updatedAt = Date()
    }

    var discontinuedReason: DiscontinuationReason? {
        get { discontinuedReasonRaw.flatMap(DiscontinuationReason.init(rawValue:)) }
        set { discontinuedReasonRaw = newValue?.rawValue }
    }

    /// Days since `discontinuedDate`, for the "Life After GLP-1" view's summary —
    /// `nil` whenever `isDiscontinued` is false or the date somehow isn't set, so
    /// callers can treat both the same way (nothing to show) without a separate check.
    var daysSinceDiscontinued: Int? {
        guard isDiscontinued, let discontinuedDate else { return nil }
        return Calendar.current.dateComponents([.day], from: discontinuedDate, to: .now).day
    }

    /// Marks this profile as discontinued as of right now. Callers (see
    /// `MedicationProfileEditView`) are expected to also cancel any pending
    /// dose/titration/refill reminder notifications, the same way `applyPlannedTitration`
    /// callers are expected to cancel the titration one — this model layer only owns
    /// the data, never `UNUserNotificationCenter` scheduling directly, matching every
    /// other mutation method on this class.
    func markDiscontinued(reason: DiscontinuationReason?) {
        isDiscontinued = true
        discontinuedDate = .now
        discontinuedReasonRaw = reason?.rawValue
        updatedAt = Date()
    }

    /// The reversal — "I'm taking it again," a real and expected outcome (a taper
    /// paused, coverage came back, a prescriber restarted treatment), not an edge case
    /// to make awkward. Clears the discontinuation fields entirely rather than leaving
    /// a "previously discontinued" trail anywhere the UI could surface it, matching
    /// this feature's whole non-judgmental framing.
    func resumeMedication() {
        isDiscontinued = false
        discontinuedDate = nil
        discontinuedReasonRaw = nil
        updatedAt = Date()
    }
}
