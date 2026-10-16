import SwiftUI

struct ProteinRingCard: View {
    let consumedGrams: Double
    let goalGrams: Double
    let streakDays: Int
    let onLogProtein: () -> Void

    private var progress: Double {
        guard goalGrams > 0 else { return 0 }
        return min(consumedGrams / goalGrams, 1)
    }

    private var remainingGrams: Double {
        max(goalGrams - consumedGrams, 0)
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Theme.primaryLight, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.primary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: progress)

                VStack(spacing: 0) {
                    // .rounded() before the Int cast — truncating a fractional
                    // gram total (e.g. 45.9g from summed manual entries) always
                    // displayed a gram lower than what was actually logged.
                    Text("\(Int(consumedGrams.rounded()))g")
                        .font(.title3.bold())
                    Text("of \(Int(goalGrams.rounded()))g")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)
            // The ring itself is decorative — the two Text labels inside it
            // already say the same numbers out loud. Without this, VoiceOver
            // announced the ring's fill/trim geometry as meaningless separate
            // elements alongside the actual numbers; combining collapses it to
            // one clear "62 grams of 140 grams" instead.
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 6) {
                Text("Protein today")
                    .font(.subheadline.weight(.semibold))
                Text(remainingGrams > 0 ? "\(Int(remainingGrams.rounded()))g to go" : "Goal reached")
                    .font(.caption)
                    .foregroundStyle(remainingGrams > 0 ? .secondary : Theme.success)

                // Only shown from a 2-day streak on: a single day isn't yet a
                // pattern worth calling out, and showing "1-day streak" on the very
                // first day would read as padding rather than genuine progress.
                //
                // Icon and color now escalate with `StreakMilestone` once a real
                // milestone has been reached (7/14/30/60/100/180/365 days) instead
                // of always showing a flat orange flame — added 2026-08-02, see
                // `StreakMilestone.swift`'s header comment for why the streak
                // needed a more visible tier system, not just this caption.
                // `DashboardView` owns the one-time celebration sheet fired when a
                // *new* milestone is first crossed; this label is just the
                // always-visible, quieter version of the same information.
                if streakDays >= 2 {
                    let milestone = StreakMilestone.highestReached(forStreakDays: streakDays)
                    Label("\(streakDays)-day streak", systemImage: milestone?.iconName ?? "flame.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(milestone?.tintColor ?? Theme.warning)
                }

                Button(action: onLogProtein) {
                    Label("Log protein", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.primary)
                .controlSize(.small)

                // Guideline 1.4.1: the daily protein target is a health calculation,
                // so its sources have to be reachable from where the number is shown,
                // not buried in Settings. This is the primary place that target
                // appears, so it's the primary place the citation has to be.
                MedicalSourcesLink(topic: .proteinTarget, label: "How this target is set")
            }

            Spacer()
        }
        .cardStyle()
    }
}

#Preview {
    ProteinRingCard(consumedGrams: 62, goalGrams: 140, streakDays: 4, onLogProtein: {})
        .padding()
}
