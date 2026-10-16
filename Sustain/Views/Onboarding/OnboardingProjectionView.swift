import SwiftUI

/// The last onboarding step, added 2026-08-03 per
/// `Sustain-Competitor-Deep-Dive-2026-08.md` §4a — the single most-cited
/// conversion lever in that report: Noom's pre-paywall moment where the app
/// visibly assembles something personalized from what the user just told it,
/// building real investment before any ask for money. Noom's specific
/// version animates a projected weight-loss curve while "building your
/// program." **This deliberately does not do that.** A projected weight
/// number over time is a personalized prediction about a real medical
/// outcome, and this app has held a consistent line against exactly that
/// category of claim everywhere else (the medication-level chart's "not a
/// real measurement" framing, the deliberate choice never to build a dosage
/// calculator, `MedicalSourcesLink` on every computed health number). Faking
/// the investment-building feeling with a real prediction it can't actually
/// back is a worse trade than getting a smaller version of the same
/// psychological effect honestly: this assembles a "plan" out of answers
/// already given (medication, dose, schedule, protein goal, and — if set —
/// direction toward a goal weight, stated as a direction, never a date or a
/// projected number) with the same staged-reveal feel, nothing invented.
struct OnboardingProjectionView: View {
    var viewModel: OnboardingViewModel

    @State private var revealedCardCount = 0

    private var cards: [(icon: String, title: String, detail: String)] {
        var result: [(icon: String, title: String, detail: String)] = []

        if viewModel.hasStartedMedication {
            result.append((
                "syringe.fill",
                "Your medication",
                "\(viewModel.medication == .custom && !viewModel.customMedicationName.isEmpty ? viewModel.customMedicationName : viewModel.medication.rawValue), \(viewModel.form.displayName.lowercased()), \(viewModel.frequency.displayName.lowercased())"
            ))
        }

        result.append((
            "fork.knife.circle.fill",
            "Your daily protein goal",
            "\(Int(viewModel.previewProteinGoalGrams))g a day, to help protect muscle while you lose weight, not just track the scale"
        ))

        if viewModel.hasTargetWeight {
            result.append((
                "arrow.up.forward.circle.fill",
                "Your direction",
                "Working from \(Int(viewModel.startingWeightLbs)) toward \(Int(viewModel.targetWeightLbs)) \(viewModel.weightUnit.abbreviation), at whatever pace is healthy for you. Sustain tracks the pattern, not a predicted date."
            ))
        }

        result.append((
            "leaf.circle.fill",
            "Lose fat. Not muscle.",
            "That's the whole idea. Every card above exists to help with that one thing."
        ))

        return result
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Your Sustain plan")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Built from what you just told us.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                VStack(spacing: 14) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        if index < revealedCardCount {
                            planCard(icon: card.icon, title: card.title, detail: card.detail)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity
                                ))
                        }
                    }
                }
                .padding(.horizontal)

                // This screen now owns the finishing button (and therefore
                // the two system permission prompts it triggers), so the
                // heads-up that used to live on the Goals step belongs here.
                // Only shown once every card has landed, so it doesn't
                // compete with the reveal it follows.
                if revealedCardCount >= cards.count {
                    Text("Next, Sustain will ask permission to send dose reminders and to sync with Apple Health. Both are optional and can be changed later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                Spacer(minLength: 24)
            }
        }
        .readableContentWidth(500)
        // `.task`, not `.onAppear` + `DispatchQueue.asyncAfter`. Caught in
        // pre-test audit: un-cancellable dispatched timers keep firing after
        // this view disappears, so backing out to the Goals step and
        // returning left stale timers from the first appearance racing the
        // reset — a visible flicker and out-of-order reveal. `.task` cancels
        // automatically on disappear, so each appearance gets a clean run.
        .task {
            revealedCardCount = 0
            for index in cards.indices {
                try? await Task.sleep(for: .seconds(index == 0 ? 0.2 : 0.35))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    revealedCardCount = index + 1
                }
            }
        }
    }

    private func planCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.primary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .cardStyle()
    }
}

#Preview {
    let viewModel = OnboardingViewModel()
    viewModel.hasTargetWeight = true
    return OnboardingProjectionView(viewModel: viewModel)
        .background(Theme.screenBackground)
}
