import SwiftData
import SwiftUI

struct ReminderSettingsView: View {
    @AppStorage("proteinCheckInEnabled") private var proteinCheckInEnabled = false
    @AppStorage("proteinCheckInHour") private var proteinCheckInHour = 18
    @AppStorage("proteinCheckInMinute") private var proteinCheckInMinute = 0

    // Report priority #5 — see `NotificationManager.scheduleRefillReminder`'s
    // header comment for why this is a generic "check your pharmacy" nudge
    // rather than a true inventory-aware feature. Opt-in like the protein
    // check-in above, not automatic like dose reminders, since not everyone
    // wants a second reminder about the same underlying dose schedule.
    @AppStorage("refillReminderEnabled") private var refillReminderEnabled = false
    @AppStorage("refillReminderDaysAhead") private var refillReminderDaysAhead = 3

    @State private var notificationManager = NotificationManager.shared
    @State private var healthKitManager = HealthKitManager.shared

    @Query(sort: \MedicationProfile.createdAt, order: .reverse) private var profiles: [MedicationProfile]
    @Query(sort: \DoseLog.date, order: .reverse) private var doseLogs: [DoseLog]

    private var profile: MedicationProfile? { profiles.first }

    private func rescheduleRefillReminder() {
        guard refillReminderEnabled, let profile, profile.hasStartedMedication else {
            notificationManager.cancelRefillReminder()
            return
        }
        let nextDoseDate = ProgressCalculator.nextDoseDate(profile: profile, logs: doseLogs)
        notificationManager.scheduleRefillReminder(
            nextDoseDate: nextDoseDate,
            daysAhead: refillReminderDaysAhead,
            medicationName: profile.displayMedicationName
        )
    }

    private var checkInTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: proteinCheckInHour, minute: proteinCheckInMinute, second: 0, of: .now
                ) ?? .now
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                proteinCheckInHour = comps.hour ?? 18
                proteinCheckInMinute = comps.minute ?? 0
                if proteinCheckInEnabled {
                    notificationManager.scheduleDailyProteinCheckIn(hour: proteinCheckInHour, minute: proteinCheckInMinute)
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                if notificationManager.isAuthorized {
                    Toggle("Daily protein check-in", isOn: Binding(
                        get: { proteinCheckInEnabled },
                        set: { enabled in
                            proteinCheckInEnabled = enabled
                            if enabled {
                                notificationManager.scheduleDailyProteinCheckIn(hour: proteinCheckInHour, minute: proteinCheckInMinute)
                            } else {
                                notificationManager.cancelDailyProteinCheckIn()
                            }
                        }
                    ))

                    if proteinCheckInEnabled {
                        DatePicker("Reminder time", selection: checkInTime, displayedComponents: .hourAndMinute)
                    }

                    Toggle("Refill reminder", isOn: Binding(
                        get: { refillReminderEnabled },
                        set: { enabled in
                            refillReminderEnabled = enabled
                            rescheduleRefillReminder()
                        }
                    ))

                    if refillReminderEnabled {
                        Stepper(
                            "\(refillReminderDaysAhead) day\(refillReminderDaysAhead == 1 ? "" : "s") before next dose",
                            value: Binding(
                                get: { refillReminderDaysAhead },
                                set: { newValue in
                                    refillReminderDaysAhead = newValue
                                    rescheduleRefillReminder()
                                }
                            ),
                            in: 1...14
                        )
                    }
                } else {
                    Button("Enable notifications") {
                        Task { await notificationManager.requestAuthorization() }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Dose reminders are scheduled automatically whenever you log a dose. A refill reminder nudges you to check your pharmacy a few days before your next dose is due, given how common GLP-1 supply shortages have been.")
            }

            Section {
                HStack {
                    Text("Sync status")
                    Spacer()
                    if healthKitManager.isAuthorized {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Connect") {
                            Task { await healthKitManager.requestAuthorization() }
                        }
                    }
                }
                if let error = healthKitManager.authorizationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("Weight and protein you log in Sustain sync to Health so your other apps stay current.")
            }
        }
        .navigationTitle("Reminders & Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notificationManager.refreshAuthorizationStatus()
        }
    }
}

#Preview {
    NavigationStack {
        ReminderSettingsView()
    }
    .modelContainer(for: [MedicationProfile.self, DoseLog.self], inMemory: true)
}
