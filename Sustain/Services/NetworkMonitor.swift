import Foundation
import Network
import Observation

/// Whether the device currently has network connectivity, watched via the
/// first-party `Network` framework (`NWPathMonitor`) — no new SPM
/// dependency, same posture as every other service in this app. Added
/// 2026-08-01 for two things: the app-wide offline banner (`OfflineBanner`,
/// shown from `ContentView`) and — indirectly — as part of the reasoning
/// behind making sign-out/delete-account always erase local data (see
/// `CloudSyncManager.eraseLocalData`'s and `AccountSectionView`'s comments):
/// once local data can no longer outlive a session, "am I online right now"
/// becomes the one honest signal for whether something you just logged has
/// actually made it to the cloud yet, worth surfacing directly.
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sustainapp.glp1.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}
