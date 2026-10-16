import SwiftUI

/// Shown once, immediately after a trial starts, only for someone who has never run
/// the AI photo-protein estimate — see `PaywallView`'s purchase-success handler for the
/// exact condition, and `Sustain-Subscription-Conversion-Research-2026-09.md` Part 8
/// item 3 for the evidence this is built on (55% of trial cancellations industry-wide
/// happen on Day 0; proving value fast matters more than a longer trial window).
///
/// Deliberately a single, low-pressure screen with an easy skip, not a hard gate —
/// this is meant to *help* someone find the feature that just got unlocked, not to
/// pressure them into using it right this second. Matches this app's own "never
/// gamified, never naggy" standing principle (`PROJECT_HANDOFF.md` §2).
struct PostTrialAIPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogProtein = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.primary)

                VStack(spacing: 8) {
                    Text("Your trial's active")
                        .font(.title2.bold())
                    Text("Try the photo protein estimate now — snap what you're eating and see it in seconds.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        showingLogProtein = true
                    } label: {
                        Text("Try it now")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)

                    Button("Maybe later") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Theme.screenBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingLogProtein, onDismiss: { dismiss() }) {
            LogProteinView(autoOpenCameraOnAppear: true)
        }
    }
}

#Preview {
    PostTrialAIPromptView()
}
