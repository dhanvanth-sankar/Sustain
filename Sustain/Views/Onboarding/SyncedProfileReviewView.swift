import SwiftUI

/// The "keep or edit" screen `OnboardingFlow` shows instead of its normal
/// step-by-step wizard, specifically for a fresh device signing into an
/// account that already has a real, started `MedicationProfile` synced down.
///
/// **Why this exists (2026-08-01)**: the previous behavior — always running
/// the full multi-step wizard, just pre-filled — was a deliberate choice (see
/// `OnboardingFlow`'s header comment) so a partially-failed sync would be
/// visible before it silently drove the Dashboard. In practice, reported
/// directly: for someone who already has a real plan on record, re-clicking
/// through 3-4 pre-filled steps just to confirm nothing changed reads as
/// friction, not reassurance. This screen keeps the actual safety property
/// (you see what synced down before it's live) while cutting the cost to a
/// single glance: one summary, two buttons. "Keep these values" finishes
/// onboarding immediately with the synced data exactly as-is. "Edit values"
/// drops into the exact same pre-filled wizard as before — nothing about
/// that flow changed, this is purely an optional shortcut in front of it.
///
/// Only shown when there's something substantive to review — a genuinely
/// first-time account (no existing profile, or one that was never actually
/// started) still goes straight into the normal wizard with empty fields,
/// same as before this existed.
///
/// **Compliance note, caught in a pre-submission audit (2026-08-01)**: this
/// screen redisplays real numbers (dose, weight) as the very first thing
/// someone sees after signing in on a fresh device — which, without the
/// disclaimer below, would have bypassed `OnboardingWelcomeView`'s explicit
/// Guideline 1.4.1 mitigation entirely. That view's own header comment
/// states the app's whole compliance framing directly: "the disclaimer
/// shouldn't live only in Settings... stating it on the first screen, before
/// any health number has been shown, sets the framing for everything after."
/// This screen can now legitimately be the *first* screen shown after
/// sign-in, so it needed the identical disclaimer + sources link, not just
/// the wizard's `.welcome` step. (These are the user's own previously-logged
/// numbers being redisplayed, not a new calculation — the stronger 1.4.1 risk
/// here was probably `MedicalSourcesLink`/disclaimer coverage having a real
/// gap at all, not this specific screen's content. Better to close it than
/// rely on that distinction holding up.)
struct SyncedProfileReviewView: View {
    let viewModel: OnboardingViewModel
    let onKeep: () -> Void
    let onEdit: () -> Void

    private var summaryLines: [String] {
        [
            viewModel.savedMedicationDisplay,
            viewModel.savedDoseDisplay.map { "Current dose: \($0)" },
            viewModel.savedStartingWeightDisplay.map { "Starting weight: \($0)" },
            viewModel.savedTargetWeightDisplay.map { "Goal weight: \($0)" },
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.primary)
                Text("We found your saved plan")
                    .font(.title2.bold())
                Text("This account already has a plan set up. Keep it as-is, or make changes before continuing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(summaryLines, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            // Same disclaimer + sources link as `OnboardingWelcomeView`'s
            // first screen, and for the same reason — see this struct's
            // header comment.
            VStack(spacing: 8) {
                Text("Sustain is a tracking tool, not medical advice. Always follow your prescriber's instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                MedicalSourcesLink(topic: .proteinTarget, label: "See our sources & citations")
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button("Keep these values", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button("Edit values", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
    }
}

#Preview {
    let viewModel = OnboardingViewModel()
    viewModel.prefill(
        from: MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 7.5,
            targetWeightLbs: 180
        ),
        latestWeight: WeightEntry(date: .now, weightLbs: 210)
    )
    return SyncedProfileReviewView(viewModel: viewModel, onKeep: {}, onEdit: {})
}
