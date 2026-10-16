import SwiftUI

struct OnboardingWelcomeView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.primary)

            VStack(spacing: 10) {
                Text("Welcome to Sustain")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("The GLP-1 companion built to protect your muscle, not just track your weight.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "syringe.fill", text: "Log doses and injections or pills, on schedule")
                featureRow(icon: "fork.knife.circle.fill", text: "Track protein so you lose fat, not muscle")
                featureRow(icon: "chart.line.uptrend.xyaxis", text: "See weight and side-effect trends over time")
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)

            // Added 2026-08-09 per Sustain-User-Feedback-Triage-2026-08.md item 1: real,
            // direct feedback (a Reddit comparison to Pokii, a competitor whose free
            // core-tracking-plus-tip-jar model gets specifically praised in its own
            // reviews) flagged that Sustain's "manual logging is free forever" principle
            // — already true, see `EntitlementManager.swift`'s own header comment — was
            // never actually stated to a user anywhere in the app. A user can't reward a
            // trust signal they never see, and a subscription-only *feeling* first
            // impression risks reading as a bait-and-switch to someone who came in
            // expecting Pokii-style openness. Placed on this very first screen,
            // deliberately before any paywall or pricing is ever shown, so it's the
            // premise, not a defensive answer to a concern raised later.
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                Text("Dose, weight, and protein logging are free, forever — no subscription required.")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)

            // Guideline 1.4.1: the disclaimer shouldn't live only in Settings, where
            // a user has to go looking for it. Stating it on the first screen, before
            // any health number has been shown, sets the framing for everything after.
            VStack(spacing: 8) {
                Text("Sustain is a tracking tool, not medical advice. Always follow your prescriber's instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                MedicalSourcesLink(topic: .proteinTarget, label: "See our sources & citations")
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .padding()
        .readableContentWidth(500)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.primary)
                .frame(width: 32)
            Text(text)
                .font(.body)
            Spacer()
        }
    }
}

#Preview {
    OnboardingWelcomeView()
}
