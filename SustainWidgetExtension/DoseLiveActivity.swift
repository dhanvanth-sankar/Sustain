import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island presentation for the dose-tracking Live
/// Activity. Started/updated/ended from the main app via
/// `Services/LiveActivityManager.swift` — this file only ever renders
/// whatever `DoseActivityAttributes.ContentState` the system hands it.
struct DoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoseActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(context.state.medicationName, systemImage: "syringe.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    RelativeDoseText(nextDoseDate: context.state.nextDoseDate)
                        .font(.caption.weight(.semibold))
                }
                ProgressView(
                    value: min(context.state.proteinConsumedGrams / max(context.state.proteinGoalGrams, 1), 1)
                ) {
                    Text("Protein today")
                        .font(.caption2)
                } currentValueLabel: {
                    Text("\(Int(context.state.proteinConsumedGrams.rounded()))g / \(Int(context.state.proteinGoalGrams.rounded()))g")
                        .font(.caption2)
                }
                .tint(.teal)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.4))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.medicationName, systemImage: "syringe.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RelativeDoseText(nextDoseDate: context.state.nextDoseDate)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(
                        value: min(context.state.proteinConsumedGrams / max(context.state.proteinGoalGrams, 1), 1)
                    ) {
                        Text("Protein today")
                            .font(.caption2)
                    }
                    .tint(.teal)
                }
            } compactLeading: {
                MinimalDoseIcon(nextDoseDate: context.state.nextDoseDate)
            } compactTrailing: {
                // Fixed 2026-08-07 — a user's real watchOS Smart Stack card
                // showed this ticking countdown truncate to "6:10:…" a second
                // after rendering "6:11:24" correctly. `Text(_:style: .timer)`
                // auto-formats as H:MM:SS/M:SS, and that string's *rendered
                // width changes second to second* as digits carry/borrow —
                // the old `.frame(width: 44)` was sized for the shorter
                // common case and SwiftUI tail-truncated the rest whenever a
                // wider string didn't fit. `.monospacedDigit()` keeps the
                // width stable per character, and `.minimumScaleFactor`
                // shrinks to fit instead of truncating as a second line of
                // defense — no combination of real values should ever clip.
                CompactTimerText(nextDoseDate: context.state.nextDoseDate)
            } minimal: {
                MinimalDoseIcon(nextDoseDate: context.state.nextDoseDate)
            }
        }
    }
}

/// Real gap, reported directly: `Text(_:style: .relative/.timer)` correctly
/// flips from counting down to counting up once a dose is overdue (that's
/// just how those two elapsed-time-since styles work), but nothing ever
/// distinguished "counting up because it's overdue" from "counting up
/// because that's just what the style does" — same number, same look,
/// no signal that anything needs attention.
///
/// All three helpers below wrap their content in `TimelineView(.periodic)`
/// specifically so the overdue color/icon swap is *reactive on its own*,
/// entirely inside this widget-extension process — a Live Activity's own
/// content only gets pushed a real update when `LiveActivityManager.refresh`
/// runs from the main app (dashboard appearance, a new dose/protein log),
/// which could be hours after the exact moment a dose actually becomes
/// overdue. `TimelineView` re-evaluates its closure on the schedule given
/// (here, every 30 seconds) independent of any app-side push, so "Overdue"
/// appears within 30 seconds of the real due time regardless of whether the
/// app happens to be open.
///
/// **Caught in a pre-submission audit, fixed before ever shipping**: the
/// first version of these three helpers applied an explicit
/// `.foregroundStyle(isOverdue ? .red : .primary)` unconditionally. The
/// `.primary` half of that was new — the original, already-approved code
/// never set an explicit color on these elements at all, letting them
/// inherit whatever this Live Activity's own presentation context provides
/// against its dark `.activityBackgroundTint(Color.black.opacity(0.4))`.
/// Forcing `.primary` risked black-on-black text in light mode, a real
/// legibility regression that a code read alone (not a device render) could
/// have shipped unnoticed. Rewritten below so the non-overdue path applies
/// no color modifier at all — pixel-identical to what already shipped and
/// was approved — and only the overdue path opts into an explicit `.red`.
private struct RelativeDoseText: View {
    let nextDoseDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if nextDoseDate < timeline.date {
                HStack(spacing: 4) {
                    Text("Overdue")
                        .fontWeight(.bold)
                    Text(nextDoseDate, style: .relative)
                }
                .foregroundStyle(.red)
            } else {
                Text(nextDoseDate, style: .relative)
            }
        }
    }
}

private struct CompactTimerText: View {
    let nextDoseDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let text = Text(nextDoseDate, style: .timer)
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 54)
            if nextDoseDate < timeline.date {
                text.foregroundStyle(.red)
            } else {
                text
            }
        }
    }
}

private struct MinimalDoseIcon: View {
    let nextDoseDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if nextDoseDate < timeline.date {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "syringe.fill")
            }
        }
    }
}

#Preview("Notification", as: .content, using: DoseActivityAttributes()) {
    DoseLiveActivity()
} contentStates: {
    DoseActivityAttributes.ContentState(
        nextDoseDate: .now.addingTimeInterval(60 * 60 * 30),
        medicationName: "Semaglutide",
        doseMg: 1.0,
        proteinConsumedGrams: 62,
        proteinGoalGrams: 140
    )
}
