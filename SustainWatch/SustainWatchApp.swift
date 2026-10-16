import SwiftUI

/// The Watch app is deliberately a single screen with a single job: show
/// today's status and let someone log a dose with one tap without reaching
/// for their phone. It has no SwiftData access, no RevenueCat, and no
/// networking of its own — see `WatchDoseView.swift`'s header comment and
/// `Sustain/Shared/PendingDoseLogQueue.swift` for how it bridges back to the
/// phone app.
@main
struct SustainWatchApp: App {
    /// Activates the Watch side of the cross-device bridge to the phone app
    /// — see `WatchConnectivityManager.swift`'s header comment. Without this,
    /// the Watch app has no way to ever receive a `WidgetSnapshot` from the
    /// phone, no matter how long the phone app has been open and signed in.
    init() {
        WatchConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchDoseView()
        }
    }
}
