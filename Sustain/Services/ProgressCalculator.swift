import Foundation

/// Pure, stateless helpers for turning raw logs into dashboard-ready numbers.
/// Kept out of the models and views so the math is independently testable.
enum ProgressCalculator {
    static func todaysTotal(_ entries: [ProteinEntry], calendar: Calendar = .current) -> Double {
        entries
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.grams }
    }

    /// Net change from the earliest logged weight to the most recent, negative = weight loss.
    static func weightChange(_ entries: [WeightEntry]) -> Double? {
        guard entries.count >= 2 else { return nil }
        let sorted = entries.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        return last.weightLbs - first.weightLbs
    }

    static func lastDose(_ logs: [DoseLog]) -> DoseLog? {
        logs.filter { !$0.skipped }.max(by: { $0.date < $1.date })
    }

    static func nextDoseDate(profile: MedicationProfile, logs: [DoseLog]) -> Date {
        let anchor = lastDose(logs)?.date ?? profile.startDate
        return profile.frequency.nextDueDate(after: anchor, scheduledWeekdays: profile.scheduledWeekdays)
    }

    /// Pre-aggregates the last 7 days into the shape `WeeklySummaryGenerator`
    /// sends to Claude — kept here, not in that file, so the arithmetic stays
    /// testable in isolation from the network call, same reasoning as every
    /// other function in this enum.
    static func weeklySummaryInput(
        profile: MedicationProfile,
        doseLogs: [DoseLog],
        weightEntries: [WeightEntry],
        proteinEntries: [ProteinEntry],
        sideEffectLogs: [SideEffectLog],
        isInMaintenanceMode: Bool = false,
        calendar: Calendar = .current
    ) -> WeeklySummaryInput {
        let weekStart = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        let twoWeeksStart = calendar.date(byAdding: .day, value: -14, to: .now) ?? .now

        let weekDoses = doseLogs.filter { $0.date >= weekStart }
        let weekWeights = weightEntries.filter { $0.date >= weekStart }.sorted { $0.date < $1.date }
        let weekProtein = proteinEntries.filter { $0.date >= weekStart }
        let weekSideEffects = sideEffectLogs.filter { $0.date >= weekStart }

        // The week immediately before the one above (days 8-14 back), used only
        // for trend comparison — see `WeeklySummaryInput`'s doc comment.
        let previousWeekWeights = weightEntries
            .filter { $0.date >= twoWeeksStart && $0.date < weekStart }
            .sorted { $0.date < $1.date }
        let previousWeekProtein = proteinEntries.filter { $0.date >= twoWeeksStart && $0.date < weekStart }

        let weightChange: Double? = weekWeights.count >= 2
            ? (weekWeights.last!.weightLbs - weekWeights.first!.weightLbs)
            : nil
        let previousWeekWeightChange: Double? = previousWeekWeights.count >= 2
            ? (previousWeekWeights.last!.weightLbs - previousWeekWeights.first!.weightLbs)
            : nil
        // Only meaningful if there was at least some logging that prior week —
        // an empty previous week isn't "0g average," it's "no data," same nil
        // convention used for weightChange above.
        let previousWeekAverageProtein: Double? = previousWeekProtein.isEmpty
            ? nil
            : previousWeekProtein.reduce(0.0) { $0 + $1.grams } / 7.0

        let topSideEffects = Dictionary(grouping: weekSideEffects, by: \.symptom)
            .map { (symptom: $0.key.displayName, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        // A flat "/7" understates the average for any profile younger than a full
        // week — the most common state for manual testing, since it's what every
        // fresh install starts from. Every day before the profile existed would
        // otherwise silently count as a zero-protein day in the denominator. Divide
        // by how many of the last 7 days the profile has actually existed for
        // instead; this collapses back to exactly 7 once a profile is a week or
        // older, so it changes nothing for the common long-term case. (`dosesExpected`
        // a few lines up has the same hardcoded-7 shape but is intentionally left
        // alone — it represents doses expected against a fixed weekly schedule, not
        // a tenure-adjusted average, which is a different and still-defensible
        // framing; see `testWeeklySummaryInput_countsLoggedAndSkippedDosesSeparately`,
        // which already locks in `dosesExpected == 7` for a same-day profile.)
        let daysSinceStart = max(
            0,
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: profile.startDate),
                to: calendar.startOfDay(for: .now)
            ).day ?? 0
        )
        let proteinDaysDivisor = Double(min(7, daysSinceStart + 1))

        let proteinGoal = profile.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.first?.weightLbs ?? 180)

        return WeeklySummaryInput(
            medicationName: profile.displayMedicationName,
            currentDoseMg: profile.currentDoseMg,
            dosesLogged: weekDoses.filter { !$0.skipped }.count,
            dosesSkipped: weekDoses.filter { $0.skipped }.count,
            // `.specificDays` expects one dose per scheduled weekday per
            // week — falls back to 1 (same as `.weekly`) if somehow no days
            // are actually selected, rather than claiming 0 are expected.
            dosesExpected: {
                switch profile.frequency {
                case .daily: return 7
                case .weekly: return 1
                case .specificDays: return max(1, profile.scheduledWeekdays.count)
                }
            }(),
            averageDailyProteinGrams: weekProtein.reduce(0.0) { $0 + $1.grams } / proteinDaysDivisor,
            proteinGoalGrams: proteinGoal,
            weightChangeLbs: weightChange,
            topSideEffects: Array(topSideEffects.prefix(3)),
            previousWeekAverageDailyProteinGrams: previousWeekAverageProtein,
            previousWeekWeightChangeLbs: previousWeekWeightChange,
            proteinGoalStreakDays: proteinGoalStreak(proteinEntries: proteinEntries, goalGrams: proteinGoal, asOf: .now, calendar: calendar),
            isPlateaued: plateauMessage(weightEntries: weightEntries, asOf: .now, calendar: calendar) != nil,
            isInMaintenanceMode: isInMaintenanceMode
        )
    }

    /// Detects a weight plateau — a stretch of consistent logging with minimal net
    /// change — and returns a supportive, non-alarming message to show in its place.
    /// Plateaus are a normal, well-documented part of GLP-1 treatment (water-weight
    /// fluctuation, temporary metabolic adaptation), but they're also a well-known
    /// point where people conclude treatment has "stopped working" and quit. Staying
    /// silent through a plateau leaves that misreading unaddressed; this surfaces a
    /// deterministic, always-available reframe instead of leaving it to the AI weekly
    /// recap, which may not run every week and shouldn't be the only place this is
    /// said.
    ///
    /// Two conditions must both hold, so a single missed weigh-in or a genuinely
    /// short logging history doesn't get misread as a plateau:
    /// - at least 3 weigh-ins spanning at least 14 days, so there's enough signal
    ///   to distinguish "holding steady" from "haven't logged much lately"
    /// - net change across that window under a threshold that scales with body
    ///   weight (`max(2 lbs, 1% of starting weight)`), so the same absolute
    ///   pound-figure doesn't misfire for people at very different starting weights
    static func plateauMessage(
        weightEntries: [WeightEntry],
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> String? {
        let windowStart = calendar.date(byAdding: .day, value: -21, to: asOf) ?? asOf
        let windowed = weightEntries
            .filter { $0.date >= windowStart && $0.date <= asOf }
            .sorted { $0.date < $1.date }

        guard windowed.count >= 3,
              let first = windowed.first,
              let last = windowed.last,
              last.date.timeIntervalSince(first.date) >= 14 * 24 * 3600,
              first.weightLbs > 0
        else { return nil }

        let netChange = last.weightLbs - first.weightLbs
        let threshold = max(2.0, first.weightLbs * 0.01)
        guard abs(netChange) <= threshold else { return nil }

        return "Your weight has held steady over the last few weeks. Plateaus like this are a normal part of GLP-1 treatment, often reflecting water retention or a temporary metabolic adjustment rather than treatment no longer working. Staying consistent with your dose and protein intake now is what typically carries people through to the next drop."
    }

    /// Consecutive days of hitting the protein goal, walking backward from `asOf`.
    /// This is the Dashboard's "forward motion" signal, deliberately a streak of one
    /// concrete daily behavior rather than a single composite score. A 0-100 score
    /// would flatten dose adherence, protein, weight trend, and side effects into
    /// one number that reads as pass/fail on a body outcome, exactly the kind of
    /// oversimplified self-judgment `plateauMessage` above exists to push back on. A
    /// streak instead rewards the one behavior that's actually inside someone's
    /// daily control, and a missed or lighter day just means the streak doesn't
    /// grow rather than the whole app handing back a lower "grade."
    ///
    /// Today isn't counted against the streak until the day is actually over: if
    /// today's total hasn't hit the goal yet, counting starts from yesterday
    /// instead, so a streak built over prior days doesn't read as broken at 9am
    /// before today even had a chance to be logged. If today already hit the goal,
    /// it's included and extends the streak immediately.
    static func proteinGoalStreak(
        proteinEntries: [ProteinEntry],
        goalGrams: Double,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        guard goalGrams > 0 else { return 0 }

        func total(on day: Date) -> Double {
            proteinEntries
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.grams }
        }

        let today = calendar.startOfDay(for: asOf)
        var day = today
        if total(on: today) < goalGrams {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
            day = yesterday
        }

        var streak = 0
        // Defensive bound, not a real product limit — guards against an unbounded
        // loop on a very old, densely-logged profile rather than reflecting any
        // actual cap on how long a streak can run.
        for _ in 0..<365 {
            guard total(on: day) >= goalGrams else { break }
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previousDay
        }
        return streak
    }
}
