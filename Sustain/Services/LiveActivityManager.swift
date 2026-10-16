import ActivityKit
import Foundation
import WidgetKit

/// Starts, updates, and ends the dose-tracking Live Activity, and keeps the
/// shared App Group snapshot (`WidgetSnapshot`) fresh for the Lock Screen /
/// home screen widget's timeline.
///
/// Gated behind Sustain+ end to end: `refresh(...)` below ends any running
/// activity and writes a non-premium snapshot unless
/// `EntitlementManager.shared.isPremium` is true. This matches the Priority-1
/// recommendation in `Sustain-Subscription-Conversion-Report-2026-08.md` —
/// "build the Live Activity + widget now, gated behind Sustain+, matching
/// GLPzy's precedent that this is a reasonable thing to charge for."
///
/// Deliberately never linked into `SustainWidgetExtension` — that target only
/// ever reads `WidgetSnapshot`, it doesn't import this file or RevenueCat.
/// `EntitlementManager`/`Purchases.shared` force-crash if accessed before
/// `Purchases.configure()` runs, which only ever happens in the main app's
/// `SustainApp.init()` — a widget extension has its own process and its own
/// lifecycle, and never goes through that init path.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    private var currentActivity: Activity<DoseActivityAttributes>?

    /// Call this alongside the existing `CloudSyncManager.shared.syncSoon(context:)`
    /// call sites — same "explicit call at the point data changed" pattern
    /// already used for cloud sync (see `LogDoseView.swift`/`LogProteinView.swift`),
    /// not a SwiftData change observer. `DashboardView` also calls this from
    /// `.onChange(of: doseLogs)` / `.onChange(of: proteinEntries)` so a save from
    /// any logging sheet is picked up without needing every call site wired
    /// individually.
    func refresh(
        profile: MedicationProfile,
        doseLogs: [DoseLog],
        proteinEntries: [ProteinEntry],
        weightFallbackLbs: Double
    ) {
        let goalGrams = profile.dailyProteinGoalGrams(fallbackWeightLbs: weightFallbackLbs)
        let snapshot = WidgetSnapshot(
            nextDoseDate: ProgressCalculator.nextDoseDate(profile: profile, logs: doseLogs),
            medicationName: profile.displayMedicationName,
            doseMg: profile.currentDoseMg,
            proteinConsumedGrams: ProgressCalculator.todaysTotal(proteinEntries),
            proteinGoalGrams: goalGrams,
            isPremium: EntitlementManager.shared.isPremium,
            updatedAt: .now
        )
        WidgetSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        // Also pushes this same snapshot to a paired Watch, if any — see
        // `PhoneConnectivityManager.swift`'s header comment for why the local
        // App-Group write above was never actually visible to the Watch app
        // on its own.
        PhoneConnectivityManager.shared.pushSnapshot(snapshot)

        guard snapshot.isPremium else {
            // Downgraded or never subscribed: end any Live Activity still
            // running rather than leaving a Sustain+ feature visible for free.
            endActivityIfNeeded()
            return
        }

        let state = DoseActivityAttributes.ContentState(
            nextDoseDate: snapshot.nextDoseDate,
            medicationName: snapshot.medicationName,
            doseMg: snapshot.doseMg,
            proteinConsumedGrams: snapshot.proteinConsumedGrams,
            proteinGoalGrams: snapshot.proteinGoalGrams
        )
        // Stale a day after the next dose is due rather than exactly at the due
        // moment — a Live Activity going "stale" grays it out on the Lock
        // Screen, and someone running a few hours late on a dose shouldn't lose
        // visibility into that dose the moment it's technically overdue.
        let staleDate = snapshot.nextDoseDate.addingTimeInterval(60 * 60 * 24)

        if let currentActivity {
            Task {
                await currentActivity.update(ActivityContent(state: state, staleDate: staleDate))
            }
        } else {
            startActivity(initialState: state, staleDate: staleDate)
        }
    }

    private func startActivity(initialState: DoseActivityAttributes.ContentState, staleDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            currentActivity = try Activity.request(
                attributes: DoseActivityAttributes(),
                content: ActivityContent(state: initialState, staleDate: staleDate),
                pushType: nil
            )
        } catch {
            // Live Activities are best-effort presentation, never core
            // functionality — a failed request (permission denied, system
            // activity limit reached, etc.) shouldn't surface as a user-facing
            // error anywhere else in the app.
        }
    }

    private func endActivityIfNeeded() {
        guard let currentActivity else { return }
        Task {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
        }
        self.currentActivity = nil
    }

    /// Reattaches to a Live Activity that's still running from before the app
    /// was last force-quit — ActivityKit activities outlive the process that
    /// started them. Call once near launch (see `DashboardView`'s `.task`) so
    /// `currentActivity` isn't nil when the app comes back and tries to
    /// `.update()` an existing activity instead of starting a redundant second
    /// one.
    func reattachToRunningActivityIfNeeded() {
        currentActivity = Activity<DoseActivityAttributes>.activities.first
    }
}
