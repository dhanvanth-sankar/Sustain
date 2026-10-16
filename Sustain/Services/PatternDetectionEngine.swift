import Foundation

/// Built directly from `marketing/Sustain-Subscription-Conversion-Research-2026-09.md`'s
/// #1 recommendation ("Pip Notices"): every premium AI feature Sustain sells today is
/// reactive — the user has to open the app and ask. This is the one proactive layer,
/// and it is deliberately NOT a new AI/network call. The research doc's own guidance was
/// explicit: "a linear trend + simple anomaly threshold is enough to start," specifically
/// because a forecasting feature that gets it wrong (a false plateau alarm, a spurious
/// pattern) risks manufacturing anxiety in a population this app is built to treat gently
/// (see that doc's Part 10 risk section, and `PROJECT_HANDOFF.md` §2's "never diagnose"
/// principle). A deterministic, auditable heuristic is the conservative choice here, not a
/// cost-cutting shortcut — every threshold below is intentionally conservative (would
/// rather under-flag than alarm someone over noise).
///
/// Pure, stateless, testable functions in the same style as `ProgressCalculator` and
/// `MedicationLevelCalculator` — this file only computes; it never decides whether a
/// pattern has already been shown or dismissed (see `PatternNoticeStore` for that) and
/// never schedules a notification (see `NotificationManager`) or renders anything (see
/// `PatternNoticeCard`). Kept separate for the same testability reasoning every other
/// calculator in this app already documents.
enum PatternDetectionEngine {
    /// One detected pattern. `stableKey` is what `PatternNoticeStore` uses to decide
    /// whether this is a genuinely new instance of a pattern type worth re-surfacing
    /// (e.g. a *new* dose increase later on) versus the same one already shown/dismissed
    /// — deliberately built from the triggering data itself (a date), not just the kind,
    /// so a real new event can still notify even if an older instance of the same kind
    /// was dismissed months ago.
    struct DetectedPattern: Identifiable {
        enum Kind: String {
            case proteinDropAfterDoseIncrease = "protein_drop_after_dose_increase"
            case weightLossPlateau = "weight_loss_plateau"
            /// Added 2026-09-27 — see `detectPostDiscontinuationRegain` below.
            case postDiscontinuationRegain = "post_discontinuation_regain"
        }

        var id: String { stableKey }
        let kind: Kind
        let stableKey: String
        let title: String
        /// Always phrased as an observation plus a discussion prompt, never a
        /// prediction stated as fact or a diagnosis — matching
        /// `SideEffectSummaryCard`/`MaintenanceGuideView`'s existing framing
        /// discipline exactly. See this file's header comment.
        let detail: String
    }

    /// Detects a meaningful protein-intake drop in the days immediately following a
    /// logged dose increase — the exact example scenario named in the research doc's
    /// Part 10 ("Your protein intake has dropped for 3 days straight, right after your
    /// dose increase"). GLP-1 appetite suppression intensifying right after a dose
    /// step-up is a well-known pattern in this population; this only ever surfaces it as
    /// something to notice, never as a warning.
    ///
    /// Conservative by design: requires a real, unambiguous dose increase (not a
    /// decrease or a re-log of the same dose), requires at least 2 logged protein days on
    /// both sides of the increase (so a single skipped day can't trigger a false
    /// positive), and requires a drop of at least a third — a smaller wobble is normal
    /// day-to-day variance, not a pattern worth interrupting someone over.
    static func detectProteinDropAfterDoseIncrease(
        doseLogs: [DoseLog],
        proteinEntries: [ProteinEntry],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> DetectedPattern? {
        let loggedDoses = doseLogs
            .filter { !$0.skipped }
            .sorted { $0.date < $1.date }
        guard loggedDoses.count >= 2 else { return nil }

        // Find the most recent genuine increase (strictly greater than the dose
        // immediately before it) within the last 10 days — old increases aren't
        // actionable anymore, and this keeps the window tight enough that "before"
        // and "after" both stay recent, comparable stretches.
        guard let increaseIndex = loggedDoses.indices.dropFirst().last(where: { idx in
            let increaseDate = loggedDoses[idx].date
            guard increaseDate >= calendar.date(byAdding: .day, value: -10, to: now) ?? .distantPast else { return false }
            return loggedDoses[idx].doseMg > loggedDoses[idx - 1].doseMg
        }) else { return nil }

        let increaseDate = loggedDoses[increaseIndex].date
        guard let windowStart = calendar.date(byAdding: .day, value: -3, to: increaseDate) else { return nil }

        let beforeGramsByDay = dailyTotals(proteinEntries, from: windowStart, to: increaseDate, calendar: calendar)
        let afterGramsByDay = dailyTotals(proteinEntries, from: increaseDate, to: now, calendar: calendar)

        guard beforeGramsByDay.count >= 2, afterGramsByDay.count >= 2 else { return nil }

        let beforeAverage = beforeGramsByDay.reduce(0, +) / Double(beforeGramsByDay.count)
        let afterAverage = afterGramsByDay.reduce(0, +) / Double(afterGramsByDay.count)

        guard beforeAverage > 0 else { return nil }
        let dropFraction = (beforeAverage - afterAverage) / beforeAverage
        guard dropFraction >= 0.33 else { return nil }

        let doseDisplay = loggedDoses[increaseIndex].doseMg.formatted(.number.precision(.fractionLength(0...2)))
        return DetectedPattern(
            kind: .proteinDropAfterDoseIncrease,
            stableKey: "\(DetectedPattern.Kind.proteinDropAfterDoseIncrease.rawValue)_\(Int(increaseDate.timeIntervalSince1970))",
            title: "Protein dropped after your dose increase",
            detail: "Since stepping up to \(doseDisplay)mg, your average daily protein looks meaningfully lower than the few days before. Appetite suppression intensifying right after a dose increase is common — worth a look, and worth mentioning at your next check-in if it continues."
        )
    }

    /// Detects a slowdown in weight-loss rate consistent with a plateau: the last 2
    /// weeks' rate of change is compared against the 2 weeks before that. Deliberately
    /// requires the person to have actually been losing at a real pace before (so this
    /// never fires on someone already stable/maintaining — that's the expected, healthy
    /// end state, not a pattern to flag), and requires real data density on both sides
    /// (at least 2 weigh-ins per 2-week window) so a single skipped week of weigh-ins
    /// can't manufacture a false plateau.
    static func detectWeightLossPlateau(
        weightEntries: [WeightEntry],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> DetectedPattern? {
        guard let fourWeeksAgo = calendar.date(byAdding: .day, value: -28, to: now),
              let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now) else { return nil }

        let priorWindow = weightEntries.filter { $0.date >= fourWeeksAgo && $0.date < twoWeeksAgo }.sorted { $0.date < $1.date }
        let recentWindow = weightEntries.filter { $0.date >= twoWeeksAgo && $0.date <= now }.sorted { $0.date < $1.date }

        guard priorWindow.count >= 2, recentWindow.count >= 2,
              let priorFirst = priorWindow.first, let priorLast = priorWindow.last,
              let recentFirst = recentWindow.first, let recentLast = recentWindow.last
        else { return nil }

        let priorLossLbs = priorFirst.weightLbs - priorLast.weightLbs
        let recentLossLbs = recentFirst.weightLbs - recentLast.weightLbs

        // Only meaningful if there was a real prior loss rate to slow down from —
        // at least 1.5 lb over 2 weeks is a conservative floor for "was actually
        // losing," well under typical early-GLP-1 rates, so this doesn't fire on
        // someone who was already essentially flat (that's maintenance, not a
        // plateau, and is handled by the existing Maintenance Program feature).
        guard priorLossLbs >= 1.5 else { return nil }

        // A slowdown to under a third of the prior rate, or an outright stall/reversal,
        // both count. Chosen to be well outside ordinary week-to-week water-weight
        // noise (which this app's existing weight-change math never tries to smooth
        // out elsewhere either, so this stays consistent with that precedent).
        guard recentLossLbs <= priorLossLbs * 0.33 else { return nil }

        return DetectedPattern(
            kind: .weightLossPlateau,
            // Keyed by a coarse two-week bucket (not an exact date) so this doesn't
            // re-fire every single day for the same ongoing plateau — the store's
            // dismissal window handles most of that already, but this keeps the key
            // itself stable across a single plateau episode.
            stableKey: "\(DetectedPattern.Kind.weightLossPlateau.rawValue)_\(Int(twoWeeksAgo.timeIntervalSince1970 / (14 * 24 * 3600)))",
            title: "Your rate of loss has slowed",
            detail: "Weight loss over the last 2 weeks looks notably slower than the 2 weeks before that. Plateaus are a normal, common part of this process, not a sign of doing something wrong — this is worth raising at your next appointment rather than something to solve alone."
        )
    }

    /// Detects renewed weight gain after a marked discontinuation — the report's
    /// single highest-conviction finding (`Sustain-GLP1-Market-PESTLE-FeatureGap-
    /// Report-2026-09.md` §15): nearly three in four GLP-1 patients discontinue
    /// within two years, usually for cost/coverage reasons rather than the
    /// medication failing, and weight regain afterward is well documented (see
    /// `MedicalSourceTopic.discontinuation`'s STEP 1 extension citation). No
    /// reviewed competitor treats this population as anything but churn; this is
    /// the one detector in the engine that looks forward from a life event
    /// (`profile.discontinuedDate`) rather than purely backward through logs.
    ///
    /// Same conservative-by-design discipline as the other two detectors: requires
    /// a real discontinuation to actually be marked, requires at least 2 weigh-ins
    /// both before and after the comparison window (so a single entry can't trigger
    /// a false positive), and requires a real regain — at least 2lb over the
    /// trailing 2 weeks — not ordinary day-to-day water-weight noise. Never fires
    /// on someone still actively titrating (`profile.isDiscontinued` must be true),
    /// and never fires in the first 2 weeks after discontinuation, since there's no
    /// meaningful "recent window" to compare yet.
    static func detectPostDiscontinuationRegain(
        profile: MedicationProfile?,
        weightEntries: [WeightEntry],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> DetectedPattern? {
        guard let profile, profile.isDiscontinued, let discontinuedDate = profile.discontinuedDate else { return nil }
        guard let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now),
              twoWeeksAgo >= discontinuedDate
        else { return nil }

        let recentWindow = weightEntries.filter { $0.date >= twoWeeksAgo && $0.date <= now }.sorted { $0.date < $1.date }
        guard recentWindow.count >= 2,
              let recentFirst = recentWindow.first, let recentLast = recentWindow.last
        else { return nil }

        let regainLbs = recentLast.weightLbs - recentFirst.weightLbs
        guard regainLbs >= 2.0 else { return nil }

        return DetectedPattern(
            kind: .postDiscontinuationRegain,
            // Keyed by the same coarse two-week bucket `detectWeightLossPlateau` uses,
            // so an ongoing regain doesn't re-fire every single day.
            stableKey: "\(DetectedPattern.Kind.postDiscontinuationRegain.rawValue)_\(Int(twoWeeksAgo.timeIntervalSince1970 / (14 * 24 * 3600)))",
            title: "Some regain since stopping",
            detail: "Your weight has moved up over the last 2 weeks since marking that you stopped your medication. This is a well-documented, common pattern, not a sign you did anything wrong — worth a look at your protein and habits in Life After GLP-1, and worth mentioning if you have a prescriber check-in coming up."
        )
    }

    /// Runs every detector and returns whatever fires. Order matters only in that a
    /// dose-related signal is checked first — if both happen to be true at once, the
    /// dose-timing one is the more actionable/specific of the two. `profile` is
    /// optional and defaults to `nil` so every existing call site keeps working
    /// unchanged; only `detectPostDiscontinuationRegain` actually uses it.
    static func detectPatterns(
        doseLogs: [DoseLog],
        proteinEntries: [ProteinEntry],
        weightEntries: [WeightEntry],
        profile: MedicationProfile? = nil,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DetectedPattern] {
        [
            detectProteinDropAfterDoseIncrease(doseLogs: doseLogs, proteinEntries: proteinEntries, calendar: calendar, now: now),
            detectWeightLossPlateau(weightEntries: weightEntries, calendar: calendar, now: now),
            detectPostDiscontinuationRegain(profile: profile, weightEntries: weightEntries, calendar: calendar, now: now),
        ].compactMap { $0 }
    }

    private static func dailyTotals(_ entries: [ProteinEntry], from start: Date, to end: Date, calendar: Calendar) -> [Double] {
        let inRange = entries.filter { $0.date >= start && $0.date < end }
        let byDay = Dictionary(grouping: inRange) { calendar.startOfDay(for: $0.date) }
        return byDay.values.map { dayEntries in dayEntries.reduce(0) { $0 + $1.grams } }
    }
}
