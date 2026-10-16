import Foundation
import WatchConnectivity

/// Bridges data between the iPhone app and the Watch app across the two
/// devices' *separate* App Group containers.
///
/// `SharedAppGroup` (`Shared/WidgetSnapshot.swift`, `Shared/PendingDoseLogQueue.swift`)
/// looks like it already bridges the phone and the Watch, since both targets
/// point at the same App Group identifier — but an App Group container is
/// per-device local storage, not iCloud-synced. Writing `WidgetSnapshot` on
/// the phone was never actually visible to the Watch's own process at all,
/// and a `PendingDoseLog` enqueued on the Watch was never visible to the
/// phone's process either. Both sides were quietly reading and writing to
/// two entirely separate files that happen to share a name.
///
/// This class (and its Watch-side counterpart,
/// `SustainWatch/WatchConnectivityManager.swift`) is the actual cross-device
/// transport, using Apple's WatchConnectivity framework. `SharedAppGroup`
/// keeps doing exactly what it always did — same-device, same-process-family
/// storage that the Lock Screen widget, Live Activity, and (on the Watch
/// side) `WatchDoseView` all still read locally — this file only moves an
/// encoded snapshot or log entry across the Bluetooth/Wi-Fi link between the
/// two devices, then hands it to the exact same local storage APIs that
/// already existed.
///
/// Found and fixed 2026-08-07 after a real user reported the Watch app
/// permanently stuck on "Open Sustain on your iPhone first," with the
/// seconds also truncating to "…" on the watch face's Live Activity card
/// (separate bug, see `DoseLiveActivity.swift`). This was a day-one design
/// gap in the Watch app (shipped 2026-08-02/06 as part of 2.1), not a
/// regression — the Watch app has never actually worked cross-device before
/// this fix, on any paired Watch.
final class PhoneConnectivityManager: NSObject {
    static let shared = PhoneConnectivityManager()
    private override init() {}

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Call once at app launch (see `SustainApp.init()`), before anything
    /// else touches WatchConnectivity. Safe to call even if the user has no
    /// paired Watch at all — `WCSession.isSupported()` covers that.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Pushes the latest `WidgetSnapshot` to the Watch. Call this everywhere
    /// `WidgetSnapshot.write(_:)` is already called (see
    /// `LiveActivityManager.refresh(...)`), not instead of it — the local
    /// App-Group write still matters for the Lock Screen widget and Live
    /// Activity, which run on this same device and never needed a network
    /// hop.
    func pushSnapshot(_ snapshot: WidgetSnapshot) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // `updateApplicationContext` keeps only the latest value (replacing
        // any not-yet-delivered previous context) and is delivered even if
        // the Watch app isn't currently running — exactly right for "what's
        // the current status," where an out-of-date snapshot is never worth
        // delivering once a newer one exists.
        try? session.updateApplicationContext(["widgetSnapshot": data])
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    // Required by WCSessionDelegate on iOS even though Sustain only ever
    // pairs with one Watch at a time — Apple's own template implementation
    // for handling a user switching Watches.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Receives a dose logged on the Watch. Decodes it back into the exact
    /// same `PendingDoseLog` shape the Watch used to enqueue only locally
    /// (and uselessly, per this file's header comment), and appends it to
    /// this device's own `PendingDoseLogQueue` — the existing, already-tested
    /// `WatchSyncManager.drainPendingDoseLogs(...)` (called from
    /// `DashboardView` on every appearance) picks it up from there with no
    /// changes needed on that side.
    ///
    /// `transferUserInfo` delivery can happen on a background queue at any
    /// time, including while the app isn't foregrounded — `PendingDoseLogQueue`'s
    /// `UserDefaults`-backed reads/writes are safe to call from here directly.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["pendingDoseLog"] as? Data,
              let log = try? JSONDecoder().decode(PendingDoseLog.self, from: data) else { return }
        PendingDoseLogQueue.enqueue(log)
    }
}
