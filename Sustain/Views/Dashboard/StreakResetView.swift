import SwiftUI

/// Shown once, the first time a *meaningful* protein-goal streak (one that
/// already reached at least `StreakMilestone.week`, i.e. was ever celebrated)
/// resets to a lower value. See `DashboardView.checkForStreakReset()` for the
/// detection logic and why the threshold matches the celebration mechanic's
/// own first tier.
///
/// This exists because of a real, previously-unaddressed gap found while
/// building the behavior-change layer this feature belongs to (see
/// `Behavior-Change-Layer-Scoping-2026-08.md`): `StreakMilestone` already
/// celebrates a streak *growing*, loudly and by design, but nothing in the
/// app ever acknowledged a streak *breaking* — the counter just silently
/// dropped to 0/1 with zero on-screen copy, anywhere. Silence isn't neutral
/// here: research on habit formation and on how people respond to a lapse in
/// a health behavior (both cited via the `MedicalSourcesLink` below) both
/// point the same direction — a missed day barely dents an established
/// routine, and responding to it with self-compassion rather than self-blame
/// predicts a stronger return to the routine, not a weaker one. This view is
/// the deliberate, sourced counterpart to `StreakMilestoneCelebrationView`:
/// same visual structure and dismiss-button language ("Keep going"), so it
/// reads as part of the same feature rather than a scolding-shaped detour
/// from it, but a calmer icon/tint (an outlined flame, not the celebration's
/// filled one) so it's visually legible as "a pause," not "an achievement,"
/// at a glance.
struct StreakResetView: View {
    /// The length of the streak that just ended, so the copy can reference a
    /// real number ("Your 12-day streak...") rather than speaking abstractly.
    let previousStreakDays: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "flame")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Text("Streak reset — that's normal")
                .font(.title2.bold())

            Text("Your \(previousStreakDays)-day streak just reset to zero. That doesn't undo the habit you built. Missing a day here and there barely affects an established routine, and what predicts whether people stick with one long-term isn't a perfect record, it's how they respond to a lapse. Today's a good day to pick it back up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            MedicalSourcesLink(topic: .consistency, label: "Why we're saying this")

            Button("Keep going", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.top, 8)
        }
        .padding(.vertical, 32)
        .presentationDetents([.medium])
    }
}

#Preview {
    StreakResetView(previousStreakDays: 12) {}
}
