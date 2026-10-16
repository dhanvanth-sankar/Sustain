import SwiftData
import SwiftUI

struct LogDoseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DoseLog.date, order: .reverse) private var doseLogs: [DoseLog]

    let profile: MedicationProfile

    @State private var date: Date = .now
    @State private var doseMg: Double
    @State private var injectionSite: InjectionSite?
    @State private var notes: String = ""
    @State private var markAsSkipped = false

    init(profile: MedicationProfile) {
        self.profile = profile
        _doseMg = State(initialValue: profile.currentDoseMg)
    }

    /// The site rotation nudge's other half — the diagram just marks this zone,
    /// this drives the "same as last time" footer warning below.
    private var lastInjectionSite: InjectionSite? {
        doseLogs.first(where: { !$0.skipped && $0.injectionSite != nil })?.injectionSite
    }

    /// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §3a: the
    /// diagram already marks last-used-site and warns on an exact repeat, but
    /// several competitors (Redose, Titer, GlucoPal) go one step further and
    /// show an actual rotation *history*, not just the single most recent
    /// site — useful for planning the next couple of shots ahead, not only
    /// avoiding the one site just used. Last 4 real (non-skipped, site-logged)
    /// doses, most recent first, matching `lastInjectionSite`'s own filter.
    /// Oldest-to-newest, deliberately. Caught in pre-test audit: `doseLogs` is
    /// sorted newest-first, so taking the first 4 and joining them with " → "
    /// read backwards — an arrow chain reads left-to-right as chronological
    /// progression, so "L. thigh → R. abdomen" was actually claiming the
    /// opposite of what happened. Reversed here so the rightmost site is the
    /// most recent one, which is also the one the diagram above badges.
    private var recentSiteHistory: [InjectionSite] {
        doseLogs
            .filter { !$0.skipped }
            .compactMap(\.injectionSite)
            .prefix(4)
            .reversed()
    }

    // A skipped dose needs no amount or site. Otherwise, a positive dose amount is
    // required — previously this only checked the injection-site condition, so a
    // 0 (or negative) dose could be saved for any non-injection form, and it would
    // also get written back into `profile.currentDoseMg` below, corrupting the
    // plan's displayed dose.
    private var canSave: Bool {
        guard !markAsSkipped else { return true }
        guard doseMg > 0 else { return false }
        return profile.form != .injection || injectionSite != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Mark as skipped instead", isOn: $markAsSkipped.animation())
                }

                Section("When") {
                    DatePicker("Date & time", selection: $date, in: ...Date.now)
                }

                if !markAsSkipped {
                    Section("Dose") {
                        HStack {
                            Text("Amount")
                            Spacer()
                            TextField("mg", value: $doseMg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("mg")
                                .foregroundStyle(.secondary)
                        }
                        Stepper("Adjust by 0.25 mg", value: $doseMg, in: 0.25...30, step: 0.25)
                            .font(.caption)
                    }

                    if profile.form == .injection {
                        Section {
                            InjectionSiteDiagram(selection: $injectionSite, lastUsedSite: lastInjectionSite)
                                .frame(maxWidth: .infinity)

                            if recentSiteHistory.count >= 2 {
                                // One Text, not an HStack of two — four
                                // abbreviated sites plus arrows runs ~55
                                // characters, which truncated to a single
                                // clipped line beside a label in a Form row.
                                // `.fixedSize` lets it wrap to as many lines
                                // as it needs instead.
                                Text("Recent rotation (oldest to newest): \(recentSiteHistory.map(\.shortDisplayName).joined(separator: " → "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } header: {
                            Text("Injection site")
                        } footer: {
                            if let lastInjectionSite, injectionSite == lastInjectionSite {
                                Label("Same as last time. Consider rotating to a different site.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warning)
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Log dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .keyboardDoneButton()
        }
    }

    private func save() {
        let log = DoseLog(
            date: date,
            doseMg: doseMg,
            form: profile.form,
            injectionSite: profile.form == .injection ? injectionSite : nil,
            skipped: markAsSkipped,
            notes: notes
        )
        modelContext.insert(log)

        if !markAsSkipped {
            profile.currentDoseMg = doseMg
            // Found while touching this line for the specific-days feature
            // below: this mutation site was missing from the last-write-wins
            // timestamp fix's original sweep (`MedicationProfileEditView
            // .save()`, `OnboardingFlow.completeOnboarding()`,
            // `applyPlannedTitration()`) — a real dose changing
            // `currentDoseMg` here is just as much an edit as those are, and
            // needs the same bump so two-device conflict resolution accounts
            // for it too.
            profile.updatedAt = Date()
        }
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)

        // Skipping a dose shouldn't move the reminder anchor — ProgressCalculator's
        // own "next due" logic (what NextDoseCard displays) already ignores skipped
        // logs and anchors on the last dose actually taken, so rescheduling here on
        // every skip would silently push the real notification a full interval past
        // what the Dashboard shows as due.
        if !markAsSkipped {
            let nextDue = profile.frequency.nextDueDate(after: date, scheduledWeekdays: profile.scheduledWeekdays)
            NotificationManager.shared.scheduleDoseReminder(at: nextDue, medicationName: profile.displayMedicationName)

            // Same "re-anchor after every real dose" logic as the dose reminder
            // above, for the opt-in refill reminder (Settings -> Reminders &
            // Health). Read directly from UserDefaults rather than an
            // `@AppStorage` property here, since this view has no other reason
            // to observe those keys and re-render on their change.
            if UserDefaults.standard.bool(forKey: "refillReminderEnabled") {
                let daysAhead = UserDefaults.standard.object(forKey: "refillReminderDaysAhead") as? Int ?? 3
                NotificationManager.shared.scheduleRefillReminder(
                    nextDoseDate: nextDue,
                    daysAhead: daysAhead,
                    medicationName: profile.displayMedicationName
                )
            }
        }

        dismiss()
    }
}

#Preview {
    LogDoseView(
        profile: MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
    )
    .modelContainer(for: [DoseLog.self], inMemory: true)
}
