import SwiftUI

/// Surfaces the prescriber-set titration plan captured in `MedicationProfileEditView`
/// — the report's named "titration schedule" item. Previously, once you set your
/// next dose step-up there was nowhere to actually see it again until the day you
/// happened to remember to edit your dose manually. Two states: counting down to
/// the change date, or (once that date arrives) a one-tap "apply now" action that
/// commits the new dose and clears the plan so the app never nags about a step-up
/// you already made.
struct TitrationScheduleCard: View {
    let profile: MedicationProfile
    let onApply: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var changeDate: Date { profile.plannedDoseChangeDate ?? .now }
    private var newDoseMg: Double { profile.plannedNextDoseMg ?? profile.currentDoseMg }
    private var newDoseText: String { newDoseMg.formatted(.number.precision(.fractionLength(0...2))) }
    private var isDue: Bool { profile.isTitrationDue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Theme.primary)
                Text("Titration plan")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isDue ? "Step-up day is here" : "Dose increases to \(newDoseText) mg")
                    .font(.subheadline)
                if isDue {
                    Text("Update to \(newDoseText) mg per your titration plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Same off-by-one fix as `NextDoseCard.relativeText` —
                    // normalizing both dates to midnight before handing them
                    // to `RelativeDateTimeFormatter` makes it count actual
                    // calendar days, not raw elapsed hours (which
                    // under-counts by one whenever `changeDate`'s
                    // time-of-day is earlier than the current moment's).
                    //
                    // Also carries the same "0 seconds" fix `NextDoseCard`
                    // needed: this `else` branch only runs when `!isDue`
                    // (`changeDate > .now`), which still allows `changeDate`
                    // to be later *today* — and normalizing both dates to
                    // midnight collapses that case to a zero-second gap,
                    // same root cause as `NextDoseCard.relativeText`'s
                    // documented bug. `isDue` itself never needs this
                    // special case (it's a direct `<=` comparison on the
                    // real, non-normalized dates, not this formatter), so
                    // only this branch needed the guard.
                    let calendar = Calendar.current
                    if calendar.isDate(changeDate, inSameDayAs: .now) {
                        Text("Later today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.relativeFormatter.localizedString(
                            for: calendar.startOfDay(for: changeDate),
                            relativeTo: calendar.startOfDay(for: .now)
                        ).capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isDue {
                Button(action: onApply) {
                    Label("Update to \(newDoseText) mg", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
            }
        }
        .cardStyle()
    }
}

#Preview("Upcoming") {
    let profile = MedicationProfile(
        medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
    )
    profile.plannedNextDoseMg = 7.5
    profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: 5, to: .now)
    return TitrationScheduleCard(profile: profile, onApply: {})
        .padding()
}

#Preview("Due") {
    let profile = MedicationProfile(
        medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
    )
    profile.plannedNextDoseMg = 7.5
    profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: -1, to: .now)
    return TitrationScheduleCard(profile: profile, onApply: {})
        .padding()
}
