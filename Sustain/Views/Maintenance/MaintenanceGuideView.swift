import SwiftData
import SwiftUI

/// The actual content behind the one-time Maintenance Program purchase — a
/// weight-maintenance range instead of a single falling target, plus a static
/// prescriber conversation guide. Deliberately framed as discussion prompts, never
/// instructions, matching the app's "log and discuss with your doctor" stance.
struct MaintenanceGuideView: View {
    @Query(sort: \MedicationProfile.createdAt, order: .reverse) private var profiles: [MedicationProfile]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue

    // Triage item 3 (`Sustain-User-Feedback-Triage-2026-08.md`): opt-in, off
    // by default, same "don't presume" reasoning as `proteinCheckInEnabled`
    // and `refillReminderEnabled` in `ReminderSettingsView` — reaching a goal
    // weight doesn't mean every user wants a different notification cadence,
    // it just means the option should exist. See `maintenanceModeToggled(_:)`
    // for what this actually changes: it swaps the daily protein check-in
    // (if it was on) for `NotificationManager.scheduleWeeklyMaintenanceCheckIn`,
    // and — via `ProgressCalculator.weeklySummaryInput(isInMaintenanceMode:)`
    // at each of this app's two call sites (`TrendsView`, `ChatCoachView`) —
    // reframes the AI weekly recap around staying in range instead of
    // continued weight loss.
    @AppStorage("maintenanceGraduationModeEnabled") private var maintenanceModeEnabled = false
    @AppStorage("proteinCheckInEnabled") private var proteinCheckInEnabled = false
    @AppStorage("proteinCheckInHour") private var proteinCheckInHour = 18
    @AppStorage("proteinCheckInMinute") private var proteinCheckInMinute = 0

    @State private var notificationManager = NotificationManager.shared

    private static let toleranceLbs: Double = 5

    private var profile: MedicationProfile? { profiles.first }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    private var range: ClosedRange<Double>? {
        guard let target = profile?.targetWeightLbs else { return nil }
        return (target - Self.toleranceLbs)...(target + Self.toleranceLbs)
    }

    private var isInRange: Bool? {
        guard let range, let latest = weightEntries.first?.weightLbs else { return nil }
        return range.contains(latest)
    }

    private let conversationPrompts = [
        "Now that I've reached my goal, should my dose change, stay the same, or gradually taper?",
        "What signs would suggest I need to adjust my maintenance dose?",
        "How should my protein or calorie targets change now that I'm not in active weight loss?",
        "If I do taper, how will we monitor for weight regain?",
        "What's a realistic maintenance weight range for me, medically?",
    ]

    // No wrapping NavigationStack here — this view is reached two different
    // ways (pushed via NavigationLink from SettingsView, which already has its
    // own outer NavigationStack, and presented as a sheet from DashboardView,
    // which needs its own). Wrapping it here worked for the sheet case but
    // broke the pushed case: a NavigationStack nested inside another one
    // swallows the outer stack's automatic back button, and my earlier fix
    // just added a second "Close" button next to it instead of replacing it.
    // Each call site now supplies its own NavigationStack/dismiss control.
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                rangeCard
                maintenanceModeCard
                conversationGuideCard
            }
            .padding()
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
        .navigationTitle("Maintenance Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// See this file's header comment on `maintenanceModeEnabled` for the
    /// full reasoning. Deliberately framed as "a lighter check-in," not "less
    /// tracking" or "you're done" — the goal is matching the nudge to where
    /// someone is now, not implying the habit itself stops mattering, which
    /// is exactly the wrong message for a program about *staying* at a
    /// healthy weight long-term.
    private var maintenanceModeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { maintenanceModeEnabled },
                set: { maintenanceModeToggled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maintenance mode")
                        .font(.headline)
                    Text("Trade daily check-ins for one weekly nudge, and shift your weekly recap to focus on staying in range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.primary)

            if maintenanceModeEnabled {
                Label("A quick check-in each week, not every day. You're not tracking less because it matters less, it's just a different phase.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            }
        }
        .cardStyle()
    }

    private func maintenanceModeToggled(_ enabled: Bool) {
        maintenanceModeEnabled = enabled
        if enabled {
            // Replaces, rather than stacks with, the daily check-in — two
            // reminders about the same underlying habit would undercut the
            // whole point of this feature (a *lighter* cadence).
            if proteinCheckInEnabled {
                proteinCheckInEnabled = false
                notificationManager.cancelDailyProteinCheckIn()
            }
            // Saturday at the same hour the daily check-in used, so this
            // doesn't need its own separate time picker for a first version.
            notificationManager.scheduleWeeklyMaintenanceCheckIn(
                weekday: 7, hour: proteinCheckInHour, minute: proteinCheckInMinute
            )
        } else {
            notificationManager.cancelWeeklyMaintenanceCheckIn()
            // Deliberately does not re-enable the daily check-in automatically
            // — that's a real behavior change a user should opt back into
            // themselves in Reminders & Health, not something this toggle
            // silently restores as a side effect of turning it off.
        }
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your maintenance range")
                .font(.headline)

            if let range {
                Text("\(displayValue(range.lowerBound).formatted(.number.precision(.fractionLength(0...1)))) – \(displayValue(range.upperBound).formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation)")
                    .font(.title2.bold())

                if let isInRange {
                    Label(
                        isInRange ? "Within range" : "Outside range",
                        systemImage: isInRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isInRange ? Theme.success : Theme.warning)
                }
            } else {
                Text("Set a goal weight in Settings to see your maintenance range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Guideline 1.4.1 — the maintenance range is a health calculation
            // (goal weight ± 5lb), so its rationale and sources are cited here.
            MedicalSourcesLink(topic: .maintenance, label: "Why a range instead of a number")
        }
        .cardStyle()
    }

    private var conversationGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before your next appointment")
                .font(.headline)

            ForEach(conversationPrompts, id: \.self) { prompt in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text(prompt)
                        .font(.subheadline)
                }
            }

            Text("These are discussion starters, not medical advice. Only your prescriber can guide dose changes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .cardStyle()
    }

    private func displayValue(_ lbs: Double) -> Double {
        WeightUnit.pounds.convert(lbs, to: weightUnit)
    }
}

#Preview {
    NavigationStack {
        MaintenanceGuideView()
    }
    .modelContainer(for: [MedicationProfile.self, WeightEntry.self], inMemory: true)
}
