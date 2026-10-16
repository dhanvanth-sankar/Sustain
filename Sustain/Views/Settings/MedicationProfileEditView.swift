import SwiftData
import SwiftUI

struct MedicationProfileEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let profile: MedicationProfile

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    // Draft copies of every editable field. Previously the medication/form/
    // frequency/dose pickers bound directly to `$profile.x` via `@Bindable`, which
    // meant they mutated the live, persisted SwiftData object the instant you
    // touched a control — so "Cancel" never actually discarded anything except the
    // goal-weight field below, which already used its own local draft state. Every
    // field now follows that same draft-then-commit-in-save() pattern.
    @State private var medication: MedicationOption
    // Only meaningful when `medication == .custom` — see
    // `MedicationProfile.customMedicationName`'s doc comment. Half-life is
    // drafted in days here (what someone actually knows from a label) and
    // converted to hours only in `save()`, same as the onboarding equivalent.
    @State private var customMedicationName: String
    @State private var customHalfLifeDays: Double?
    @State private var form: MedicationForm
    @State private var frequency: DoseFrequency
    @State private var scheduledWeekdays: Set<Int>
    @State private var currentDoseMg: Double
    @State private var hasTargetWeight: Bool
    @State private var targetWeightDisplay: Double
    @State private var hasPlannedTitration: Bool
    @State private var plannedNextDoseMgDraft: Double
    @State private var plannedDoseChangeDateDraft: Date
    // Added 2026-09-27 for the "Life After GLP-1" feature — see
    // `MedicationProfile.isDiscontinued`'s doc comment. Drafted the same way every
    // other field on this screen is, so toggling it doesn't take effect until Save,
    // and Cancel discards it like anything else here.
    @State private var isDiscontinuedDraft: Bool
    @State private var discontinuedReasonDraft: DiscontinuationReason?

    /// Captured at open time (not read live from `profile`, which only changes on
    /// save) so the title/footer can tell "adding medication for the first time"
    /// apart from "editing an existing plan" for the duration this sheet is open.
    private let wasStarted: Bool

    init(profile: MedicationProfile) {
        self.profile = profile
        self.wasStarted = profile.hasStartedMedication
        _medication = State(initialValue: profile.medication)
        _customMedicationName = State(initialValue: profile.customMedicationName ?? "")
        _customHalfLifeDays = State(initialValue: profile.customHalfLifeHours.map { $0 / 24 })
        _form = State(initialValue: profile.form)
        _frequency = State(initialValue: profile.frequency)
        _scheduledWeekdays = State(initialValue: profile.scheduledWeekdays)
        _currentDoseMg = State(initialValue: profile.currentDoseMg)
        _hasTargetWeight = State(initialValue: profile.targetWeightLbs != nil)
        let unit = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnitRaw") ?? "") ?? .pounds
        _targetWeightDisplay = State(initialValue: WeightUnit.pounds.convert(profile.targetWeightLbs ?? profile.startingWeightLbs ?? 160, to: unit))
        _hasPlannedTitration = State(initialValue: profile.plannedNextDoseMg != nil)
        _plannedNextDoseMgDraft = State(initialValue: profile.plannedNextDoseMg ?? profile.currentDoseMg)
        _plannedDoseChangeDateDraft = State(initialValue: profile.plannedDoseChangeDate ?? Calendar.current.date(byAdding: .day, value: 28, to: .now) ?? .now)
        _isDiscontinuedDraft = State(initialValue: profile.isDiscontinued)
        _discontinuedReasonDraft = State(initialValue: profile.discontinuedReason)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Medication", selection: $medication) {
                        ForEach(MedicationOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker("Form", selection: $form) {
                        ForEach(MedicationForm.allCases) { form in
                            Text(form.displayName).tag(form)
                        }
                    }
                    Picker("Frequency", selection: $frequency) {
                        ForEach(DoseFrequency.allCases) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    // comp-010 in sustain-pros-and-cons.json — see
                    // `OnboardingMedicationView`'s matching field for the
                    // same feature on first setup.
                    if medication == .custom {
                        TextField("Medication name", text: $customMedicationName)
                        HStack {
                            Text("Half-life (days)")
                            Spacer()
                            TextField("Optional", value: $customHalfLifeDays, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                    }
                    // Only relevant for a compounded/custom program on an
                    // exact-days schedule — see `WeekdaySelector`'s doc
                    // comment.
                    if frequency == .specificDays {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Which days?")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            WeekdaySelector(selectedWeekdays: $scheduledWeekdays)
                        }
                    }
                } header: {
                    Text("Medication")
                } footer: {
                    if !wasStarted {
                        Text("You haven't started a medication yet. Fill this in once you begin treatment.")
                    }
                }

                Section("Current dose") {
                    HStack {
                        Text("Dose")
                        Spacer()
                        TextField("mg", value: $currentDoseMg, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("mg").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("I have a planned dose increase", isOn: $hasPlannedTitration.animation())
                    if hasPlannedTitration {
                        if let suggestion = standardScheduleSuggestion {
                            Button {
                                applyStandardScheduleSuggestion(suggestion)
                            } label: {
                                Label(
                                    "Use standard schedule: \(suggestion.step.doseMg.formatted(.number.precision(.fractionLength(0...2)))) mg on \(suggestion.date.formatted(.dateTime.month(.abbreviated).day()))",
                                    systemImage: "wand.and.stars"
                                )
                                .font(.subheadline)
                            }
                        }
                        HStack {
                            Text("New dose")
                            Spacer()
                            TextField("mg", value: $plannedNextDoseMgDraft, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("mg").foregroundStyle(.secondary)
                        }
                        DatePicker("Change date", selection: $plannedDoseChangeDateDraft, displayedComponents: .date)
                    }
                } header: {
                    Text("Titration plan")
                } footer: {
                    // Guideline 1.4.1: a suggested dose step is medical information,
                    // so the prescribing information it comes from has to be
                    // reachable from the screen that suggests it.
                    VStack(alignment: .leading, spacing: 6) {
                        if standardScheduleSuggestion != nil {
                            Text("If your prescriber has already scheduled your next dose step-up, enter it here, or use the suggestion above, based on \(profile.displayMedicationName)'s typical dosing schedule from its FDA-approved prescribing information. Sustain never changes a dose on its own, and your prescriber's plan always takes precedence.")
                            MedicalSourcesLink(topic: .dosing, label: "Where these dose schedules come from")
                        } else {
                            Text("If your prescriber has already scheduled your next dose step-up, add it here. We'll remind you on the day and let you apply it with one tap.")
                        }
                    }
                }

                // Added 2026-09-27, only shown once a medication has actually been
                // started (matching this file's own `wasStarted` distinction elsewhere)
                // — someone who hasn't started anything yet has nothing to mark as
                // stopped. Placed after the titration section, before goal weight: this
                // is a status change, not part of the active dosing plan those sections
                // describe.
                if wasStarted {
                    Section {
                        Toggle("I've stopped taking \(profile.displayMedicationName)", isOn: $isDiscontinuedDraft.animation())
                        if isDiscontinuedDraft {
                            Picker("Reason (optional)", selection: $discontinuedReasonDraft) {
                                Text("Prefer not to say").tag(DiscontinuationReason?.none)
                                ForEach(DiscontinuationReason.allCases.filter { $0 != .preferNotToSay }) { reason in
                                    Text(reason.displayName).tag(DiscontinuationReason?.some(reason))
                                }
                            }
                        }
                    } header: {
                        Text("Status")
                    } footer: {
                        if isDiscontinuedDraft {
                            Text("This pauses dose reminders and opens Life After GLP-1 on your Dashboard. You can mark yourself as taking it again anytime, from there or here.")
                        } else {
                            Text("If you've stopped taking \(profile.displayMedicationName), for any reason, mark it here. Nothing about this is permanent.")
                        }
                    }
                }

                Section {
                    Toggle("I have a goal weight", isOn: $hasTargetWeight.animation())
                    if hasTargetWeight {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Goal weight")
                            // Scroll wheel, not a typed number (explicit
                            // request) — see `WeightWheelPicker`'s doc
                            // comment.
                            WeightWheelPicker(weight: $targetWeightDisplay, unit: weightUnit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Goal weight")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your daily protein target is calculated from this goal (or your current weight if none is set), at about 0.8g per pound.")
                        MedicalSourcesLink(topic: .proteinTarget, label: "See the sources for this")
                    }
                }
            }
            .navigationTitle(wasStarted ? "Medication plan" : "Add medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(currentDoseMg <= 0 || (frequency == .specificDays && scheduledWeekdays.isEmpty))
                }
            }
            .keyboardDoneButton()
        }
    }

    /// The standard next-step suggestion for whatever medication/dose is currently
    /// selected, if `TitrationSchedule` has a known ladder and the current dose
    /// matches one of its rungs. `nil` for unmatched medications (`.compounded`,
    /// `.other`, no ladder defined) or doses that don't line up with a known rung —
    /// the manual fields below always work regardless, this is purely an optional
    /// shortcut.
    private var standardScheduleSuggestion: (step: TitrationStep, date: Date)? {
        guard let step = TitrationSchedule.nextStep(for: medication, form: form, currentDoseMg: currentDoseMg),
              let weeks = TitrationSchedule.weeksUntilNextStep(for: medication, form: form, currentDoseMg: currentDoseMg),
              let date = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: .now)
        else { return nil }
        return (step, date)
    }

    /// Fills the manual fields from the standard-schedule suggestion — still just a
    /// draft the person can review, edit, or discard before `save()` ever touches
    /// the persisted profile, same as if they'd typed the values in themselves.
    private func applyStandardScheduleSuggestion(_ suggestion: (step: TitrationStep, date: Date)) {
        plannedNextDoseMgDraft = suggestion.step.doseMg
        plannedDoseChangeDateDraft = suggestion.date
    }

    private func save() {
        // Captured before any field is mutated below, so this reflects a genuine
        // transition (off -> on, or on -> off) rather than "is currently true."
        let discontinuationJustMarked = isDiscontinuedDraft && !profile.isDiscontinued
        let discontinuationJustCleared = !isDiscontinuedDraft && profile.isDiscontinued

        let frequencyChanged = frequency != profile.frequency
        // A `.specificDays` schedule can change which days are selected
        // without `frequency` itself changing — that's still a real
        // schedule change the reminder needs to reflect, so it's checked
        // separately rather than folded into `frequencyChanged` above.
        let scheduledWeekdaysChanged = frequency == .specificDays && scheduledWeekdays != profile.scheduledWeekdays
        // Saving from this screen is what actually starts medication tracking —
        // whether that's a genuine first-time "Add medication" (wasStarted false)
        // or just a routine edit to an already-started plan.
        let justStarted = !profile.hasStartedMedication

        profile.medication = medication
        profile.customMedicationName = medication == .custom && !customMedicationName.isEmpty ? customMedicationName : nil
        profile.customHalfLifeHours = medication == .custom ? customHalfLifeDays.map { $0 * 24 } : nil
        profile.form = form
        profile.frequency = frequency
        profile.scheduledWeekdays = scheduledWeekdays
        profile.currentDoseMg = currentDoseMg
        profile.targetWeightLbs = hasTargetWeight ? weightUnit.convert(targetWeightDisplay, to: .pounds) : nil
        profile.plannedNextDoseMg = hasPlannedTitration ? plannedNextDoseMgDraft : nil
        profile.plannedDoseChangeDate = hasPlannedTitration ? plannedDoseChangeDateDraft : nil
        profile.hasStartedMedication = true

        if isDiscontinuedDraft {
            // Reuses `discontinuedDate` from a prior mark rather than resetting it to
            // now, if the toggle was already on and only the reason changed — only a
            // genuine off->on transition should reset the "days since" clock.
            if discontinuationJustMarked {
                profile.markDiscontinued(reason: discontinuedReasonDraft)
            } else {
                profile.discontinuedReasonRaw = discontinuedReasonDraft?.rawValue
            }
        } else if discontinuationJustCleared {
            profile.resumeMedication()
        }

        profile.updatedAt = Date()
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)

        if discontinuationJustMarked {
            // Nothing left to be reminded about once someone has said they've
            // stopped — same "cancel what's no longer relevant" precedent
            // `applyPlannedTitration`'s callers and `maintenanceModeToggled` already
            // establish elsewhere in this app.
            NotificationManager.shared.cancelDoseReminder()
            NotificationManager.shared.cancelTitrationReminder()
            NotificationManager.shared.cancelRefillReminder()
            AnalyticsManager.track(.medicationDiscontinuationMarked)
        } else if discontinuationJustCleared {
            AnalyticsManager.track(.medicationResumedAfterDiscontinuation)
        }

        // Only touch the reminder schedule if the dosing frequency changed, or if
        // this is the first time a dose reminder has ever made sense for this
        // profile. This used to run unconditionally on every save — including
        // edits that only touched dose amount or goal weight — anchored on `.now`,
        // which silently pushed the reminder a full interval out from whatever
        // moment you happened to save, regardless of where you actually were in
        // your real dosing cycle.
        // `!isDiscontinuedDraft` guards both blocks below — a discontinuation mark
        // already cancelled these above, and someone marking themselves discontinued
        // in the same save that happens to also touch frequency/titration fields
        // shouldn't have this immediately reschedule what was just turned off.
        if !isDiscontinuedDraft {
            if frequencyChanged || scheduledWeekdaysChanged || justStarted {
                NotificationManager.shared.scheduleDoseReminder(
                    at: profile.frequency.nextDueDate(after: .now, scheduledWeekdays: profile.scheduledWeekdays),
                    medicationName: profile.displayMedicationName
                )
            }

            if hasPlannedTitration {
                NotificationManager.shared.scheduleTitrationReminder(
                    at: plannedDoseChangeDateDraft,
                    newDoseMg: plannedNextDoseMgDraft,
                    medicationName: profile.displayMedicationName
                )
            } else {
                NotificationManager.shared.cancelTitrationReminder()
            }
        }

        dismiss()
    }
}

#Preview {
    MedicationProfileEditView(
        profile: MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
    )
    .modelContainer(for: [MedicationProfile.self], inMemory: true)
}
