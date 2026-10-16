import SwiftUI

/// Reads the same `WidgetSnapshot` shape the Lock Screen widget and Live
/// Activity use, but from *this device's own* App Group container
/// (`group.com.sustainapp.glp1`) — no direct SwiftData or RevenueCat access
/// from this process, matching the constraint already documented in
/// `Services/LiveActivityManager.swift` for the widget extension.
/// `snapshot.isPremium` is trusted as-is rather than re-checked against
/// RevenueCat, since re-checking would mean linking RevenueCat into a
/// process that never calls `Purchases.configure()`.
///
/// **What actually keeps this data current**: `WatchConnectivityManager`
/// (see its own header comment, and `Services/PhoneConnectivityManager.swift`
/// on the phone side) pushes a fresh `WidgetSnapshot` from the phone over
/// WatchConnectivity and writes it into *this* device's local App Group
/// container whenever it arrives — the App Group name being identical on
/// both targets does not, on its own, mean this device ever sees what the
/// phone wrote to its own copy. Found and fixed 2026-08-07 after this view
/// was permanently stuck on `notSetUpState` on a real paired Watch,
/// regardless of the phone app's actual state.
///
/// Logging a dose here doesn't touch the real store at all — it sends a
/// `PendingDoseLog` to the phone via `WatchConnectivityManager
/// .sendPendingDoseLog(_:)`, queued for guaranteed delivery even if the
/// phone isn't reachable right now, and the phone app drains it into a real
/// `DoseLog` the next time it's opened (see `Services/WatchSyncManager.swift`).
/// This means a dose logged here won't show up anywhere else (Dashboard,
/// cloud sync, dose reminders) until the phone app is actually foregrounded
/// — an accepted limitation given the Watch app has no way to wake the phone
/// in the background, documented in `WatchSyncManager.swift`'s header
/// comment.
struct WatchDoseView: View {
    // Added 2026-08-06, capturing the Apple Watch App Store Connect
    // screenshot: a Watch Simulator launched standalone from the scheme
    // picker (rather than as part of an actually-paired iPhone+Watch
    // Simulator pair) has its own isolated App Group container, so
    // `WidgetSnapshot.read()` never sees anything the phone app wrote — the
    // real screen would only ever show `notSetUpState` here, which is a
    // true and correct state but not something worth submitting as this
    // app's one required Watch screenshot. Same fabricated-data pattern
    // `ScreenshotModeSeeder` already uses for the phone app's screenshots,
    // scoped to this one property so nothing else in this file needs to
    // know the difference. Never compiles into a Release build.
    #if SCREENSHOT_MODE
    @State private var snapshot: WidgetSnapshot? = WidgetSnapshot(
        nextDoseDate: Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now,
        medicationName: "Wegovy 1.7mg",
        doseMg: 1.7,
        proteinConsumedGrams: 86,
        proteinGoalGrams: 120,
        isPremium: true,
        updatedAt: .now
    )
    #else
    @State private var snapshot: WidgetSnapshot? = WidgetSnapshot.read()
    #endif
    @State private var justLogged = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let snapshot, snapshot.isPremium {
                    statusSection(snapshot)
                    logButton
                } else if snapshot?.isPremium == false {
                    lockedState
                } else {
                    notSetUpState
                }
            }
            .padding()
        }
        .onAppear {
            // Refreshes on every wrist-raise / app reopen, and also the
            // instant a fresh push arrives from the phone (see `.onReceive`
            // below) — `WatchConnectivityManager` is what actually keeps this
            // current now; this `.onAppear` read is a fallback for whatever
            // was last delivered, not the only way this data ever updates.
            // Skipped under `SCREENSHOT_MODE` — see the fabricated `snapshot`
            // initializer above; this would otherwise immediately overwrite
            // it with the real (empty) read the moment the view appears.
            #if !SCREENSHOT_MODE
            snapshot = WidgetSnapshot.read()
            #endif
            justLogged = false
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchConnectivityManager.snapshotUpdatedNotification)) { _ in
            #if !SCREENSHOT_MODE
            snapshot = WidgetSnapshot.read()
            #endif
        }
    }

    @ViewBuilder
    private func statusSection(_ snapshot: WidgetSnapshot) -> some View {
        VStack(spacing: 2) {
            Text(snapshot.medicationName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(snapshot.nextDoseDate, style: .relative)
                .font(.headline)
                .minimumScaleFactor(0.7)
            Text("until next dose")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Gauge(value: min(snapshot.proteinConsumedGrams / max(snapshot.proteinGoalGrams, 1), 1)) {
            Text("Protein")
        }
        .tint(.teal)
        Text("\(Int(snapshot.proteinConsumedGrams.rounded()))g of \(Int(snapshot.proteinGoalGrams.rounded()))g")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var logButton: some View {
        Button {
            let log = PendingDoseLog()
            // The local enqueue below is same-device only (this Watch's own
            // App Group container — see `PhoneConnectivityManager.swift`'s
            // header comment) and on its own never reaches the phone. Kept
            // anyway as harmless local record-keeping; `sendPendingDoseLog`
            // is what actually gets this dose to the phone, via
            // `WCSession.transferUserInfo`, queued for guaranteed delivery
            // even if the phone isn't reachable right now.
            PendingDoseLogQueue.enqueue(log)
            WatchConnectivityManager.shared.sendPendingDoseLog(log)
            justLogged = true
        } label: {
            Label(justLogged ? "Logged" : "Log dose", systemImage: justLogged ? "checkmark.circle.fill" : "syringe.fill")
        }
        .tint(.teal)
        .disabled(justLogged)
        .padding(.top, 4)
    }

    private var lockedState: some View {
        VStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Sustain+ feature")
                .font(.headline)
            Text("Subscribe in the iPhone app to use the Watch app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var notSetUpState: some View {
        VStack(spacing: 4) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            Text("Open Sustain on your iPhone first")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    WatchDoseView()
}
