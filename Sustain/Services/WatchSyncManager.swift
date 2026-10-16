import Foundation
import SwiftData

/// Drains `PendingDoseLogQueue` — entries recorded by the Watch app's one-tap
/// "Log dose" button — into real `DoseLog` rows. Runs on the same "every
/// Dashboard appearance" cadence `syncHealthKitEntries()` and
/// `syncCloudIfSignedIn()` already use, rather than a push/notification-based
/// mechanism — the Watch app has no way to wake the phone app in the
/// background, so this is a best-effort bridge: a dose logged on the Watch
/// shows up in the main app (and syncs to other devices) the next time the
/// phone app is actually opened, not instantly.
@MainActor
enum WatchSyncManager {
    static func drainPendingDoseLogs(profile: MedicationProfile, modelContext: ModelContext) {
        let pending = PendingDoseLogQueue.readAll()
        guard !pending.isEmpty else { return }

        for entry in pending.sorted(by: { $0.date < $1.date }) {
            let log = DoseLog(date: entry.date, doseMg: profile.currentDoseMg, form: profile.form)
            modelContext.insert(log)
        }
        profile.updatedAt = Date()
        try? modelContext.save()
        PendingDoseLogQueue.clear()

        CloudSyncManager.shared.syncSoon(context: modelContext)

        // Re-anchor both reminders off the latest Watch-logged dose, same as
        // `LogDoseView.save()` does for a phone-logged dose.
        guard let latestDate = pending.map(\.date).max() else { return }
        let nextDue = profile.frequency.nextDueDate(after: latestDate, scheduledWeekdays: profile.scheduledWeekdays)
        NotificationManager.shared.scheduleDoseReminder(at: nextDue, medicationName: profile.displayMedicationName)
        if UserDefaults.standard.bool(forKey: "refillReminderEnabled") {
            let daysAhead = UserDefaults.standard.object(forKey: "refillReminderDaysAhead") as? Int ?? 3
            NotificationManager.shared.scheduleRefillReminder(
                nextDoseDate: nextDue,
                daysAhead: daysAhead,
                medicationName: profile.displayMedicationName
            )
        }
    }
}
