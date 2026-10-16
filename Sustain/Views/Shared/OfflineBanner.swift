import SwiftUI

/// Thin banner shown at the top of the app whenever `NetworkMonitor` reports
/// no connectivity — explicit request: "when the device is offline, a
/// message at the top of the screen should say it's offline and new
/// additions will be saved but synced to the account when the app is opened
/// with internet." Deliberately reassuring, not alarming: nothing about
/// this app's local-first design actually breaks while offline (every log
/// screen writes to SwiftData first, sync is always a separate, best-effort
/// step after — see `CloudSyncManager.syncSoon`), so the banner's whole job
/// is to explain that plainly rather than read like an error state.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You're offline: new entries save on this device and sync once you're back online.")
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.15))
        .foregroundStyle(Theme.warning)
    }
}

#Preview {
    OfflineBanner()
}
