import Foundation

/// A relative medication-level estimate over time, built purely from logged doses
/// and each medication's published elimination half-life. This is the "level
/// simulation" / "concentration chart" class of feature that three independent
/// competitor teardowns in `Documentation/sustain-pros-and-cons.json` flagged as a
/// real, repeatedly-validated gap (OptimizeGLP's half-life decay chart, Pokii's
/// "Level Simulation" plotted alongside weight, Vita AI's GLP-1 concentration
/// chart — comp-001, comp-011, comp-023). It's also a concrete answer to real,
/// specific user skepticism logged in the same file (fb-001/fb-002, r/Mounjaro):
/// "why would a dose increase matter to protein intake?" — appetite suppression
/// tracks how much medication is still active in the body, not the calendar date
/// of the last shot, and this chart is the first place that's actually visible.
///
/// **This is explicitly NOT a real pharmacokinetic measurement.** No blood test,
/// no absorption-phase modeling (subcutaneous injections don't reach peak
/// concentration instantly — this treats every dose as if it did, which is a
/// simplification, not a clinical claim), no per-patient clearance rate, no units
/// of actual concentration (ng/mL). It is a standard, unitless first-order-decay
/// superposition — each still-active dose contributes `dose * exp(-k * elapsed
/// hours)`, summed — using only the single number every GLP-1's own prescribing
/// information publishes (elimination half-life). `MedicationLevelCard` labels
/// this explicitly as an estimate and links `MedicalSourceTopic.medicationLevel`'s
/// citations, following the same disclosure pattern already established for the
/// protein-target formula and titration schedules (Guideline 1.4.1).
enum MedicationLevelCalculator {
    /// One point on the relative-level curve. `relativeLevel` is deliberately
    /// unitless (not ng/mL) — this app has no way to know a real per-patient
    /// clearance rate, so the y-axis is meaningful only in relation to itself
    /// (higher means more medication is estimated still active), not as an
    /// absolute clinical value.
    struct LevelPoint: Identifiable {
        let date: Date
        var id: Date { date }
        let relativeLevel: Double
    }

    /// Builds a daily relative-level curve for the last `days` days (default 42,
    /// wide enough to show a full titration cycle at the most common 4-week step
    /// interval plus some runway before the first step). Returns an empty array if
    /// the medication has no known half-life (`.compounded`/`.other`, or `.custom`
    /// with no half-life entered) or no non-skipped doses exist yet — both are the
    /// caller's cue to show an empty state instead of an empty chart.
    ///
    /// `customHalfLifeHours` overrides `medication.eliminationHalfLifeHours` when
    /// present — the caller (`MedicationLevelCard`, via
    /// `MedicationProfile.effectiveHalfLifeHours`) passes this for a `.custom`
    /// medication with a user-entered half-life (comp-010 in
    /// `sustain-pros-and-cons.json`). `nil` for every fixed-case medication, which
    /// falls through to the enum's own published value unchanged.
    ///
    /// Doses outside the `days` window still contribute to the curve if they
    /// haven't fully decayed (a long-half-life medication like semaglutide can
    /// still meaningfully contribute weeks later) — only the *display* window is
    /// `days` wide, not the set of doses considered.
    static func relativeLevelSeries(
        medication: MedicationOption,
        doseLogs: [DoseLog],
        days: Int = 42,
        asOf: Date = .now,
        calendar: Calendar = .current,
        customHalfLifeHours: Double? = nil
    ) -> [LevelPoint] {
        guard let halfLifeHours = customHalfLifeHours ?? medication.eliminationHalfLifeHours, halfLifeHours > 0 else { return [] }
        let relevantDoses = doseLogs.filter { !$0.skipped }
        guard !relevantDoses.isEmpty else { return [] }

        let decayConstant = log(2) / halfLifeHours
        let startOfToday = calendar.startOfDay(for: asOf)
        let windowStartDate = calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday

        // Real UX bug, caught from a screenshot: someone who just started (one
        // dose logged today) got a chart showing a flat zero line for the
        // entire `days`-wide window, then a near-vertical spike on the very
        // last point — technically accurate (there genuinely was no
        // medication in their system before their first dose), but reads as
        // broken, not "day one." Clamping the start to whichever is later —
        // the fixed lookback window, or the day of the earliest relevant
        // dose — means a new user's chart starts exactly where their real
        // history starts, with no fabricated empty runway before it.
        // Established users (first dose further back than `days`) are
        // unaffected: `windowStartDate` is later in that case, so this is a
        // no-op for them, same fixed-width window as before.
        let earliestDoseDay = relevantDoses.map { calendar.startOfDay(for: $0.date) }.min() ?? startOfToday
        let startDate = max(windowStartDate, earliestDoseDay)

        func level(asOf evalDate: Date) -> Double {
            relevantDoses.reduce(0.0) { total, dose in
                let elapsedHours = evalDate.timeIntervalSince(dose.date) / 3600
                guard elapsedHours >= 0 else { return total }
                return total + dose.doseMg * exp(-decayConstant * elapsedHours)
            }
        }

        var points: [LevelPoint] = []
        var cursor = startDate
        while cursor <= startOfToday {
            // Every historical point is evaluated at its own midnight — except
            // today's, which is evaluated at the actual current moment (`asOf`),
            // not midnight. Otherwise a dose logged earlier *today* wouldn't
            // register at all until tomorrow's point (today's midnight is always
            // earlier than a same-day dose's timestamp, so `elapsedHours` would be
            // negative and the dose would be silently excluded) — the chart would
            // look like it hadn't noticed a dose someone just logged.
            let evalMoment = (cursor == startOfToday) ? asOf : cursor
            points.append(LevelPoint(date: cursor, relativeLevel: level(asOf: evalMoment)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return points
    }

    /// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §3c:
    /// GLPzy's "Estimated Exposure" projects *forward* from today, not just
    /// backward — showing what's left in the system before the next dose,
    /// rather than only what the curve looked like historically. This reuses
    /// the exact same first-order-decay math as `relativeLevelSeries` above
    /// (same `MedicationLevelCalculator` header comment's caveats apply
    /// identically — if anything, more strongly, since a *projected* number
    /// invites more confidence than a historical one, not less): every
    /// already-logged dose still contributes its decaying remainder, and if
    /// `upcomingDose` is given (the next scheduled dose date/amount, computed
    /// by the caller from `MedicationProfile.frequency.nextDueDate`), it's
    /// treated as a dose that will happen exactly on schedule and contributes
    /// to the curve only from its own date forward — before that date, its
    /// `elapsedHours` is negative and it's excluded by the same guard the
    /// historical function already relies on, so "not taken yet" falls out
    /// of the existing math for free rather than needing special-casing.
    ///
    /// `upcomingDose` being `nil` (no `MedicationProfile` to derive a next-
    /// due date from, or a `.compounded`/"take as needed" schedule with no
    /// fixed next date) still returns a meaningful curve: just the known
    /// doses decaying forward with nothing new added, which is honestly what
    /// "no more doses assumed" should show rather than an error state.
    static func projectedLevelSeries(
        medication: MedicationOption,
        doseLogs: [DoseLog],
        daysForward: Int = 7,
        asOf: Date = .now,
        calendar: Calendar = .current,
        customHalfLifeHours: Double? = nil,
        upcomingDose: (date: Date, doseMg: Double)? = nil
    ) -> [LevelPoint] {
        guard let halfLifeHours = customHalfLifeHours ?? medication.eliminationHalfLifeHours, halfLifeHours > 0 else { return [] }
        var relevantDoses: [(date: Date, doseMg: Double)] = doseLogs
            .filter { !$0.skipped }
            .map { (date: $0.date, doseMg: $0.doseMg) }
        guard !relevantDoses.isEmpty else { return [] }

        if let upcomingDose, upcomingDose.date > asOf {
            relevantDoses.append(upcomingDose)
        }

        let decayConstant = log(2) / halfLifeHours
        let startOfToday = calendar.startOfDay(for: asOf)

        func level(asOf evalDate: Date) -> Double {
            relevantDoses.reduce(0.0) { total, dose in
                let elapsedHours = evalDate.timeIntervalSince(dose.date) / 3600
                guard elapsedHours >= 0 else { return total }
                return total + dose.doseMg * exp(-decayConstant * elapsedHours)
            }
        }

        var points: [LevelPoint] = [LevelPoint(date: asOf, relativeLevel: level(asOf: asOf))]
        var cursor = startOfToday
        for _ in 0..<daysForward {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
            guard cursor > asOf else { continue }
            points.append(LevelPoint(date: cursor, relativeLevel: level(asOf: cursor)))
        }
        return points
    }
}
