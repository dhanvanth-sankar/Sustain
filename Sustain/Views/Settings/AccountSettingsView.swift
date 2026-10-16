import SwiftUI

/// Dedicated "Account & Sync" screen — 2026-08-01, explicit request: account
/// settings used to be one inline `Section` (`AccountSectionView`) sitting in
/// the middle of the main Settings list, mixed in with weight units,
/// reminders, and the maintenance guide. Given how much actually lives under
/// it (sign-in status, sync status/now, sign out, delete account) and how
/// consequential some of those actions are, it's now its own screen, reached
/// via a single link pinned to the very top of Settings — see
/// `SettingsView`'s `accountRow`. `AccountSectionView` itself is unchanged
/// and does all the real work here; this is just the navigation
/// destination/container around it, matching the same
/// `NavigationLink { SomeView() }` → `Form { ... }` pattern every other
/// pushed Settings screen already uses (`ReminderSettingsView`,
/// `MaintenanceGuideView`, `MedicalSourcesView`).
struct AccountSettingsView: View {
    var body: some View {
        Form {
            AccountSectionView()
        }
        .navigationTitle("Account & Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AccountSettingsView()
    }
    .modelContainer(for: [
        MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
    ], inMemory: true)
}
