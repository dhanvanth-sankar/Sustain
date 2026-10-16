import Foundation
import Observation
import UserNotifications

@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private(set) var isAuthorized = false

    static let doseReminderID = "dose-reminder"
    static let proteinCheckInID = "daily-protein-checkin"
    static let titrationReminderID = "titration-reminder"
    static let refillReminderID = "refill-reminder"
    static let maintenanceCheckInID = "weekly-maintenance-checkin"

    @MainActor
    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            isAuthorized = false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
        await MainActor.run { self.isAuthorized = authorized }
    }

    /// Schedules a one-time reminder for the next dose. Callers are expected to
    /// re-schedule after each dose is logged so this always points at the next one.
    func scheduleDoseReminder(at date: Date, medicationName: String) {
        cancelDoseReminder()
        guard date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Dose reminder"
        content.body = "It's time for your \(medicationName) dose."
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: Self.doseReminderID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelDoseReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.doseReminderID])
    }

    func scheduleDailyProteinCheckIn(hour: Int, minute: Int) {
        cancelDailyProteinCheckIn()

        let content = UNMutableNotificationContent()
        content.title = "Protein check-in"
        content.body = "Log today's protein to stay on track with muscle preservation."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: Self.proteinCheckInID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelDailyProteinCheckIn() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.proteinCheckInID])
    }

    /// One-time reminder for a planned dose step-up, set from the prescriber's
    /// titration schedule (`MedicationProfile.plannedDoseChangeDate`). Fires at 9am
    /// on the change date itself rather than matching a specific time-of-day, since
    /// the date picker that sets this only ever captures a day, not a time.
    func scheduleTitrationReminder(at date: Date, newDoseMg: Double, medicationName: String) {
        cancelTitrationReminder()
        guard date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Dose increase scheduled today"
        content.body = "Time to step up your \(medicationName) dose to \(newDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg, per your titration plan."
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = 9
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: Self.titrationReminderID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelTitrationReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.titrationReminderID])
    }

    /// Report priority #5 (`Sustain-Subscription-Conversion-Report-2026-08.md`):
    /// GLP-1 shortages are a real, ongoing anxiety for this user base, but no
    /// reliable per-pharmacy real-time inventory data exists to build a genuinely
    /// "shortage-aware" feature against (see
    /// `Sustain-Remaining-Priorities-Scoping-2026-08.md`). This is the honest,
    /// buildable fallback identified there: a generic "check your pharmacy has
    /// your next dose" nudge timed a few days ahead of the next dose, reusing the
    /// same computed due-date `LogDoseView` already schedules
    /// `scheduleDoseReminder` from. Fires at 9am on the target day, same choice
    /// `scheduleTitrationReminder` makes, for the same reason: this only ever has
    /// a day to work with, not a specific time.
    func scheduleRefillReminder(nextDoseDate: Date, daysAhead: Int, medicationName: String) {
        cancelRefillReminder()
        guard let fireDate = Calendar.current.date(byAdding: .day, value: -daysAhead, to: nextDoseDate),
              fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Check your pharmacy"
        content.body = "Your next \(medicationName) dose is due in \(daysAhead) days. Worth confirming your pharmacy has it in stock, given ongoing supply issues."
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: fireDate)
        comps.hour = 9
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: Self.refillReminderID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelRefillReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.refillReminderID])
    }

    /// Triage item 3 (`Sustain-User-Feedback-Triage-2026-08.md`): a real,
    /// undecided product question — should a user who's reached and is
    /// maintaining their goal weight keep getting the same daily protein
    /// check-in as someone in active weight loss? Decided yes to building a
    /// lighter alternative, not a removal: a once-a-week nudge, replacing
    /// (not stacking with) the daily one, framed around the maintenance
    /// range rather than a daily gram goal. See `MaintenanceGuideView.swift`
    /// for where this is toggled and why it's opt-in rather than automatic.
    ///
    /// Fires on a fixed weekday rather than "7 days after last log" — repeats
    /// via `UNCalendarNotificationTrigger` the same way the daily check-in
    /// does, just with a `.weekday` component added to the date-matching
    /// components instead of only hour/minute.
    func scheduleWeeklyMaintenanceCheckIn(weekday: Int, hour: Int, minute: Int) {
        cancelWeeklyMaintenanceCheckIn()

        let content = UNMutableNotificationContent()
        content.title = "Maintenance check-in"
        content.body = "A quick weigh-in or log keeps your maintenance range current. No need to log daily anymore, just when it's convenient."
        content.sound = .default

        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: Self.maintenanceCheckInID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelWeeklyMaintenanceCheckIn() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.maintenanceCheckInID])
    }

    static let patternNoticeID = "pattern-notice"

    /// `PatternDetectionEngine`'s proactive layer (see that file and
    /// `Sustain-Subscription-Conversion-Research-2026-09.md` Part 10) — the one
    /// notification in this app triggered by a detected data pattern rather than a
    /// fixed schedule. Deliberately scheduled for the next morning at 9am, the same
    /// choice `scheduleTitrationReminder`/`scheduleRefillReminder` already make, rather
    /// than firing immediately: the pattern was just computed while the app is open and
    /// the Dashboard card showing it is already on screen in front of the person, so an
    /// instant push would be redundant, not proactive. A next-day nudge is the case
    /// this genuinely helps — someone who saw the card, didn't act, and closed the app.
    ///
    /// Uses a fixed identifier (not one per pattern), so scheduling a new one replaces
    /// any still-pending old one rather than stacking — this app should never queue up
    /// multiple pattern notifications at once, matching `DashboardView`'s own "surface
    /// only the single highest-priority unseen pattern" rule.
    ///
    /// `title` becomes the notification body and does name the specific pattern (e.g.
    /// "Protein dropped after your dose increase"), which is visible on a locked
    /// device. Consistent with existing precedent in this file, not a new exposure:
    /// `scheduleDoseReminder`/`scheduleTitrationReminder` already put the medication
    /// name and exact dose in mg into lock-screen-visible notification bodies.
    func schedulePatternNotification(title: String) {
        cancelPatternNotification()
        guard let fireDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pip noticed something"
        content.body = title
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: fireDate)
        comps.hour = 9
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: Self.patternNoticeID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelPatternNotification() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.patternNoticeID])
    }
}
