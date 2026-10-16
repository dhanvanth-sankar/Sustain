import SwiftUI

struct NextDoseCard: View {
    let profile: MedicationProfile
    let nextDoseDate: Date
    let onLogDose: () -> Void

    private var isOverdue: Bool { nextDoseDate < .now }

    // Behavior-change layer, added 2026-08-07 (see `StreakResetView.swift`'s
    // header comment for the feature this belongs to). Only shows once a
    // dose is overdue by more than a day, not the moment it's a few minutes
    // late — a dose due at 9am reading as a "setback" by 9:05 would be a false
    // alarm, not a supportive nudge. Deliberately says nothing about what to
    // do with the dose itself (take it now, skip it, adjust timing) — that's
    // squarely the "always defer to your prescriber" line every other
    // dosing-adjacent surface in this app already holds (see
    // `MedicalSourceTopic.dosing`'s explainer); this is only about the
    // emotional framing of being late, not the medical decision.
    private var isSignificantlyOverdue: Bool {
        nextDoseDate.addingTimeInterval(24 * 3600) < .now
    }

    // RelativeDateTimeFormatter is expensive to construct (loads locale data) and this
    // card re-renders on every Dashboard body evaluation, including unrelated log
    // changes elsewhere on the screen — build it once and reuse it, not per render.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // Real bug, reported directly: a dose due Wednesday, 5 calendar days out,
    // showed as "in 4 days." Root cause: `RelativeDateTimeFormatter` computes
    // from the raw elapsed time between the two dates, not calendar days —
    // `nextDoseDate` keeps whatever time-of-day the anchoring dose was
    // originally logged/started at, which is often earlier in the day than
    // whatever moment someone happens to open the app, so the literal
    // elapsed interval reads as just under 5*24 hours and rounds down.
    // Normalizing both dates to midnight before handing them to the
    // formatter makes the difference an exact multiple of a day, matching
    // how a person actually counts "days until" (calendar days, not exact
    // hours) — this only changes what's fed to the formatter, not
    // `nextDoseDate` itself, which still needs its real time-of-day for
    // `isOverdue` and the absolute date/time shown elsewhere on this card.
    //
    // Second real bug, also reported directly: "it says 0 seconds" once a
    // dose is actually due. Root cause is the fix directly above: when
    // `nextDoseDate` falls on the same calendar day as `.now` (whether it's
    // overdue by a few hours or due later today), `startOfDay(for:)` maps
    // *both* dates to the exact same midnight instant, so the formatter is
    // handed a zero-second difference — and with the default `.numeric`
    // `dateTimeStyle`, `RelativeDateTimeFormatter` renders that literally as
    // "0 seconds ago" / "in 0 seconds" rather than anything resembling
    // "today." The day-normalization fix above is still correct for actual
    // multi-day gaps; it just can't be the whole story, since collapsing to
    // midnight is exactly what makes two different times on the *same* day
    // indistinguishable to the formatter. This is handled as its own
    // explicit case rather than trying to coax `RelativeDateTimeFormatter`
    // into a "today" string, since that behavior isn't guaranteed by its
    // documented API and this app has already been burned once by an
    // unverified assumption about this exact formatter.
    private var relativeText: String {
        let calendar = Calendar.current
        guard !calendar.isDate(nextDoseDate, inSameDayAs: .now) else {
            return isOverdue ? "Today" : "Later today"
        }
        return Self.relativeFormatter.localizedString(
            for: calendar.startOfDay(for: nextDoseDate),
            relativeTo: calendar.startOfDay(for: .now)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(profile.displayMedicationName, systemImage: profile.form.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(profile.currentDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isOverdue ? "Dose overdue" : "Next dose")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(nextDoseDate, format: .dateTime.weekday(.wide).month().day())
                    .font(.title2.bold())
                Text(relativeText.capitalized)
                    .font(.footnote)
                    .foregroundStyle(isOverdue ? Theme.warning : .secondary)

                if isSignificantlyOverdue {
                    Text("A late dose doesn't undo your progress. If it's been a while, checking in with your prescriber is a good next step.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Button(action: onLogDose) {
                Label("Log dose", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
        }
        .cardStyle()
    }
}

#Preview {
    NextDoseCard(
        profile: MedicationProfile(
            medication: .zepbound,
            form: .injection,
            frequency: .weekly,
            startDate: .now,
            currentDoseMg: 5
        ),
        nextDoseDate: Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now,
        onLogDose: {}
    )
    .padding()
}
