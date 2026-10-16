import SwiftUI

/// The Dashboard surface for `PatternDetectionEngine` — see that file's header comment
/// and `marketing/Sustain-Subscription-Conversion-Research-2026-09.md`'s Part 10 for the
/// full reasoning. Shown only when `PatternNoticeStore.unseenPatterns` returns something
/// genuinely new; entirely absent otherwise (never an empty "nothing to report" state,
/// matching this app's existing "don't show a card with nothing to say" convention used
/// by `recentSideEffectsCard`/`maintenanceCard`'s own conditional-display pattern in
/// `DashboardView`).
///
/// **Free users see a teaser, not a push notification.** This is a deliberate line drawn
/// against the mission brief's own dark-pattern warnings (§18/§29): proactively pushing a
/// locked insight at someone who has never started a trial would read as manufactured
/// urgency/FOMO bait, not a genuine benefit of paying. So the asymmetry here is
/// specifically: a free user who *opens the app on their own* can see that Sustain
/// noticed something (the observation is real, not fabricated to sell a subscription —
/// see `PatternDetectionEngine`, which runs identically regardless of entitlement), but
/// the detail and any notification are premium-only. This is the same "hard paywall on
/// AI features, always shown directly" principle `PROJECT_HANDOFF.md` §2 already
/// documents, applied to a new feature rather than a new exception to it.
struct PatternNoticeCard: View {
    let pattern: PatternDetectionEngine.DetectedPattern
    let isPremium: Bool
    let onUpgrade: () -> Void
    let onDismiss: () -> Void
    let onMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pip noticed something")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(pattern.title)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                if isPremium {
                    Menu {
                        Button("Not now", action: onDismiss)
                        Button("Don't show this type again", role: .destructive, action: onMute)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    // Keeps the dismiss/mute controls reachable without adding a second
                    // full-width row — same reasoning `AccountSectionView`'s existing
                    // overflow menus already use for lower-frequency actions.
                    .menuStyle(.borderlessButton)
                }
            }

            if isPremium {
                Text(pattern.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Deliberately does not restate the real detail text here — see this
                // file's header comment on why this stays a teaser, not a locked
                // preview of the actual finding. `PaywallView(trigger: .patternDetection)`
                // is where the real feature is actually pitched.
                Text("Sustain+ turns your own logged history into proactive notices like this one, before you have to ask.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("See how", action: onUpgrade)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .controlSize(.small)
            }
        }
        .cardStyle()
    }
}

private struct PatternNoticeCardPreview: View {
    var body: some View {
        VStack(spacing: 16) {
            PatternNoticeCard(
                pattern: .init(
                    kind: .proteinDropAfterDoseIncrease,
                    stableKey: "preview",
                    title: "Protein dropped after your dose increase",
                    detail: "Since stepping up to 7.5mg, your average daily protein looks meaningfully lower than the few days before."
                ),
                isPremium: true,
                onUpgrade: {}, onDismiss: {}, onMute: {}
            )
            PatternNoticeCard(
                pattern: .init(
                    kind: .weightLossPlateau,
                    stableKey: "preview2",
                    title: "Your rate of loss has slowed",
                    detail: "Weight loss over the last 2 weeks looks notably slower than the 2 weeks before that."
                ),
                isPremium: false,
                onUpgrade: {}, onDismiss: {}, onMute: {}
            )
        }
        .padding()
    }
}

#Preview {
    PatternNoticeCardPreview()
}
