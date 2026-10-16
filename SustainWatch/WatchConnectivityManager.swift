import Foundation
import WatchConnectivity

/// Watch-side counterpart to `Sustain/Services/PhoneConnectivityManager.swift`
/// — see that file's header comment for the full explanation of why this
/// exists (App Group containers don't sync across devices, only within one).
///
/// Every incoming snapshot from the phone is written into this device's own
/// local `WidgetSnapshot` App-Group store, exactly the way `LiveActivityManager`
/// does on the phone — `WatchDoseView.snapshot` keeps reading it through the
/// same `WidgetSnapshot.read()` call it always did; only the *source* of that
/// local data changes (a cross-device push instead of a same-device write),
/// not how it's consumed.
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()
    private override init() {}

    /// Posted after a fresh snapshot from the phone has been written to this
    /// device's local store, so `WatchDoseView` can refresh immediately
    /// instead of waiting for the next wrist-raise / app reopen.
    static let snapshotUpdatedNotification = Notification.Name("WatchConnectivityManager.snapshotUpdated")

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Call once at app launch (see `SustainWatchApp.init()`).
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Called from `WatchDoseView`'s log button. Sends the pending dose log
    /// to the phone via `transferUserInfo`, which queues it for guaranteed
    /// background delivery rather than requiring the phone to be reachable
    /// at this exact moment — matching this feature's own documented
    /// tolerance for the phone app only being opened later (see
    /// `WatchSyncManager.swift`'s header comment).
    func sendPendingDoseLog(_ log: PendingDoseLog) {
        guard let session, let data = try? JSONEncoder().encode(log) else { return }
        session.transferUserInfo(["pendingDoseLog": data])
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    /// `applicationContext` delivery can happen on a background queue at any
    /// time, including before the Watch app's first `WatchDoseView.onAppear`
    /// — `WidgetSnapshot.write(_:)`'s `UserDefaults`-backed write is safe to
    /// call from here directly.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["widgetSnapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        WidgetSnapshot.write(snapshot)
        NotificationCenter.default.post(name: Self.snapshotUpdatedNotification, object: nil)
    }
}
