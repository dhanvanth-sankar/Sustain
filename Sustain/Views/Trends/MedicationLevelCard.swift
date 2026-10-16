import Charts
import SwiftUI

/// The relative medication-level chart — see `MedicationLevelCalculator`'s header
/// comment for the full rationale (a real, repeatedly-validated competitor gap,
/// and a concrete answer to real user skepticism about why dose matters to
/// protein intake, both logged in `Documentation/sustain-pros-and-cons.json`).
///
/// Deliberately has no y-axis labels: the underlying value is unitless by
/// construction (see the calculator's doc comment), and putting numbers on an
/// axis — even unlabeled ones — invites reading them as something clinically
/// precise, like a real concentration in ng/mL, which this explicitly is not.
/// Only the shape of the curve (rising after a dose, decaying between doses) is
/// meant to be legible; the "Estimate, not a real measurement" caption and the
/// `MedicalSourcesLink` say the rest.
struct MedicationLevelCard: View {
    let medication: MedicationOption
    let doseLogs: [DoseLog]
    /// How many days of history to plot — the same free/premium window every
    /// other Trends chart already respects, passed down from `TrendsView` rather
    /// than decided here, so this card doesn't drift out of sync with the rest of
    /// the screen's gating if that window ever changes.
    var days: Int = 42
    /// Added 2026-08-02 for comp-010 (`sustain-pros-and-cons.json`): a `.custom`
    /// medication has no name or half-life of its own on the enum (see
    /// `MedicationOption.custom`'s doc comment) — both live on the profile
    /// instead. Defaults preserve this card's exact prior behavior for every
    /// fixed-case medication (`medication.rawValue`, no override).
    var displayName: String? = nil
    var customHalfLifeHours: Double? = nil
    /// Added 2026-08-03 for comp-012 (`sustain-pros-and-cons.json`): Pokii plots
    /// weight on the same chart as its level simulation, and that combination is
    /// flagged as a direct answer to real user skepticism (fb-001/fb-002,
    /// r/Mounjaro) about why a dose has anything to do with what else someone
    /// tracks — seeing the two shapes move together is more convincing than
    /// being told they're related. Defaults to empty, so every existing call
    /// site (including the `#Preview` below) keeps rendering exactly as before.
    var weightEntries: [WeightEntry] = []
    /// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §3c —
    /// see `MedicationLevelCalculator.projectedLevelSeries`'s doc comment for
    /// the full reasoning. `nil` (the default, matching every other new
    /// optional on this card) means "no known next dose to project from,"
    /// which quietly skips the forward segment entirely rather than
    /// guessing at one.
    var upcomingDose: (date: Date, doseMg: Double)? = nil

    private var resolvedName: String { displayName ?? medication.rawValue }

    private var points: [MedicationLevelCalculator.LevelPoint] {
        MedicationLevelCalculator.relativeLevelSeries(
            medication: medication,
            doseLogs: doseLogs,
            days: days,
            customHalfLifeHours: customHalfLifeHours
        )
    }

    private var projectedPoints: [MedicationLevelCalculator.LevelPoint] {
        MedicationLevelCalculator.projectedLevelSeries(
            medication: medication,
            doseLogs: doseLogs,
            daysForward: 7,
            customHalfLifeHours: customHalfLifeHours,
            upcomingDose: upcomingDose
        )
    }

    /// One point on the overlaid weight line. `scaledValue` is deliberately not
    /// `weightLbs` itself — this card's y-axis is unitless by design (see the
    /// header comment), so a real-pound value would either be invisible (if it's
    /// numerically much larger than `relativeLevel`) or force a second axis this
    /// chart intentionally doesn't have. `BodyCompositionChartView`'s own doc
    /// comment already ruled out a dual-axis chart for two *real-unit* series
    /// (body fat % vs. lean lbs) as too easy to misread; here one series (the
    /// medication level) is already synthetic/unitless, so instead of stacking a
    /// second chart, the weight line is min-max rescaled into the *same* range
    /// the level line is currently occupying. That trades "you can read the
    /// actual weight off this line" (never true here, matching the level line's
    /// own no-axis rule) for "you can see whether the two shapes move together"
    /// — which is the entire point of this feature, not a compromise on it.
    private struct WeightOverlayPoint: Identifiable {
        let date: Date
        var id: Date { date }
        let scaledValue: Double
    }

    private var weightOverlayPoints: [WeightOverlayPoint] {
        guard let windowStart = points.first?.date, points.count >= 2 else { return [] }
        let relevant = weightEntries
            .filter { $0.date >= windowStart }
            .sorted { $0.date < $1.date }
        guard relevant.count >= 2 else { return [] }

        // Caught during manual testing (2026-08-03): this used to take
        // min/max from `relevant` (only the entries inside the current
        // window). With exactly two points in view, those two values *are*
        // the min and max by definition — so the line was mathematically
        // guaranteed to span the chart's entire vertical range regardless of
        // how small the real-world difference was. A 0.2 lb fluctuation
        // between two close-together weigh-ins looked identical to a 20 lb
        // swing, which is the opposite of "shape comparison." Scaling
        // against the user's *full* weight history instead means the
        // amplitude reflects genuine variability — two points that are
        // actually close together relative to the person's overall range
        // now render as a relatively flat line, not a forced full-height
        // spike.
        let allWeights = weightEntries.map(\.weightLbs)
        // Scaled against BOTH series' levels, not just the historical ones —
        // caught in pre-test audit: the chart's y-domain now includes
        // `projectedPoints`, whose peak can exceed the historical maximum
        // (a scheduled future dose spikes the curve). Scaling the weight line
        // to the historical range alone left it visibly compressed into the
        // lower part of the plot instead of spanning it, which defeats the
        // shape-comparison this overlay exists for.
        let levels = (points + projectedPoints).map(\.relativeLevel)
        guard let minWeight = allWeights.min(), let maxWeight = allWeights.max(), maxWeight > minWeight,
              let minLevel = levels.min(), let maxLevel = levels.max(), maxLevel > minLevel else {
            return []
        }

        return relevant.map { entry in
            let fraction = (entry.weightLbs - minWeight) / (maxWeight - minWeight)
            let scaled = minLevel + fraction * (maxLevel - minLevel)
            return WeightOverlayPoint(date: entry.date, scaledValue: scaled)
        }
    }

    /// Whether the projected segment actually includes a future dose, or is
    /// just the existing doses decaying with nothing new added. Caught in
    /// pre-test audit: `TrendsView` always passes a non-nil `upcomingDose`,
    /// but `ProgressCalculator.nextDoseDate` returns a date in the *past*
    /// when a dose is overdue — `projectedLevelSeries` correctly ignores a
    /// past dose, but the card's caption still claimed the projection
    /// "assumes your next dose happens exactly as scheduled," which is the
    /// opposite of what's drawn in exactly the situation (an overdue dose)
    /// where someone is most likely to be looking at this chart.
    private var projectionIncludesUpcomingDose: Bool {
        guard let upcomingDose else { return false }
        return upcomingDose.date > .now
    }

    // The chart's own y-axis is deliberately unlabeled (see the header comment),
    // so Swift Charts' default per-data-point VoiceOver behavior would announce
    // dozens of unitless numbers with no context — worse than useless. This gives
    // one plain-language summary instead: whether the estimate is currently
    // trending up or down, which is the one thing the curve's shape is actually
    // meant to convey.
    private var trendDescription: String {
        guard points.count >= 2 else { return "Not enough data yet" }
        let recent = points.suffix(min(7, points.count))
        guard let first = recent.first, let last = recent.last else { return "Not enough data yet" }
        let delta = last.relativeLevel - first.relativeLevel
        let threshold = max(first.relativeLevel, last.relativeLevel) * 0.05
        let levelDescription = abs(delta) <= threshold
            ? "Roughly steady over the past week"
            : (delta > 0 ? "Rising over the past week" : "Declining over the past week")
        guard !weightOverlayPoints.isEmpty else { return levelDescription }
        return levelDescription + ". Weight trend for the same period is also shown for comparison."
    }

    // Extended 2026-08-03 to include `projectedPoints` in the domain — before
    // the forward-projection feature, `points` alone always spanned the
    // card's full plotted range. Now the chart can extend a week past
    // `points.last`, so the tick/domain math has to consider both series'
    // dates, not just the historical one, or the projected segment would
    // render past the right edge of the plot entirely.
    private var allPlottedDates: [Date] {
        points.map(\.date) + projectedPoints.map(\.date)
    }

    private var xAxisTickDates: [Date] {
        guard let first = allPlottedDates.first, let last = allPlottedDates.last, last > first else {
            return allPlottedDates
        }
        let tickCount = 4
        let interval = last.timeIntervalSince(first) / Double(tickCount - 1)
        return (0..<tickCount).map { first.addingTimeInterval(interval * Double($0)) }
    }

    // Same asymmetric-padding fix WeightChartView uses, and for the identical
    // reason: the last tick lands exactly on the last data point by construction,
    // which clips its label at the plot's right edge without extra trailing room.
    private var xAxisDomain: ClosedRange<Date> {
        guard let first = allPlottedDates.first, let last = allPlottedDates.last, last > first else {
            let now = Date.now
            return now...now.addingTimeInterval(1)
        }
        let span = last.timeIntervalSince(first)
        return first.addingTimeInterval(-span * 0.02)...last.addingTimeInterval(span * 0.18)
    }

    // Caught during manual testing (2026-08-03): with no explicit y-domain,
    // Swift Charts auto-scales to fit every mark on the chart — but
    // `AreaMark` implicitly fills down to a *zero baseline* unless told
    // otherwise, which silently pulled 0 into the auto-computed range even
    // when every real value (historical, projected, and the weight overlay,
    // which is deliberately rescaled to match the level line's own min/max)
    // sat well above it. That compressed the actual data into a narrow band
    // and, combined with the weight overlay's rescale being computed against
    // stale min/max values, could visually read as a line running past the
    // plot's edge. Making the y-domain explicit — spanning only the values
    // actually drawn, with a small symmetric padding — guarantees every mark
    // stays inside the frame no matter how sparse or skewed the underlying
    // test data is.
    private var yAxisDomain: ClosedRange<Double> {
        let allValues = points.map(\.relativeLevel)
            + projectedPoints.map(\.relativeLevel)
            + weightOverlayPoints.map(\.scaledValue)
        guard let minValue = allValues.min(), let maxValue = allValues.max() else {
            return 0...1
        }
        guard maxValue > minValue else {
            // Every plotted value is identical (e.g. exactly one dose logged,
            // no decay elapsed yet) — a zero-span domain would make Swift
            // Charts pick an arbitrary range, so fall back to a fixed
            // padding around the single value instead.
            let padding = max(abs(maxValue) * 0.1, 0.1)
            return (minValue - padding)...(maxValue + padding)
        }
        let span = maxValue - minValue
        let padding = span * 0.12
        return (minValue - padding)...(maxValue + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Medication level")
                    .font(.headline)
                Spacer()
                MedicalSourcesLink(topic: .medicationLevel, label: "What is this?")
            }

            if (customHalfLifeHours ?? medication.eliminationHalfLifeHours) == nil {
                unavailableState
            } else if points.isEmpty {
                emptyState
            } else {
                if !weightOverlayPoints.isEmpty {
                    HStack(spacing: 16) {
                        legendItem(color: Theme.primary, label: "Medication level")
                        legendItem(color: Theme.warning, label: "Weight trend")
                    }
                }

                // Every LineMark below carries an explicit `series:`. Real bug
                // caught in pre-test audit: Swift Charts derives series identity
                // from `.value`-based grouping or an explicit `series:` argument,
                // NOT from a constant `.foregroundStyle(Color)`. Without these,
                // all three line groups were treated as one continuous series,
                // drawing stray connector lines jumping from the last historical
                // point back to the first weight point and again to the first
                // projected point.
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Level", point.relativeLevel),
                            series: .value("Series", "level")
                        )
                        .foregroundStyle(Theme.primary)
                        // Changed from `.catmullRom` (2026-08-03): the actual
                        // root cause of the chart still clipping past its
                        // frame edge even after adding an explicit
                        // `yAxisDomain` above. Catmull-Rom is a spline that
                        // can overshoot past the data's real values *between*
                        // points, especially right where two segments meet at
                        // a sharp angle (like the peak between a rising
                        // historical line and a declining projection) — so no
                        // amount of padding computed from the data values
                        // themselves would catch it, since the overshoot
                        // isn't at a data point, it's in the curve drawn
                        // between them. `.monotone` is designed specifically
                        // to never exceed the range of its adjacent points,
                        // which fixes this at the source.
                        .interpolationMethod(.monotone)
                        // Caught during manual testing (2026-08-03): a new or
                        // same-day-only user (every dose logged today) has
                        // exactly one historical point, and Swift Charts
                        // can't draw a *line* through a single point — so
                        // with no symbol, the historical series rendered
                        // nothing at all, and only the dashed projection
                        // (which starts at that same value) was visible,
                        // making today's real level look like a guess. A
                        // symbol is placed per-point regardless of whether
                        // there's a second point to draw a line to, so this
                        // guarantees at least one solid marker for real,
                        // logged history even on day one.
                        .symbol(.circle)

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Level", point.relativeLevel)
                        )
                        .foregroundStyle(Theme.primaryLight)
                        // Same `.monotone` fix as the LineMark above.
                        .interpolationMethod(.monotone)
                    }

                    ForEach(weightOverlayPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.scaledValue),
                            series: .value("Series", "weight")
                        )
                        .foregroundStyle(Theme.warning)
                        // Same `.monotone` fix as above.
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }

                    // Forward projection (comp-deep-dive §3c) — same primary
                    // color as the historical line so it visually reads as a
                    // continuation of the same curve, distinguished only by
                    // a dashed stroke and no fill, so "this part hasn't
                    // happened yet" is legible without a second legend entry
                    // competing with the weight-overlay one above.
                    ForEach(projectedPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Level", point.relativeLevel),
                            series: .value("Series", "projection")
                        )
                        .foregroundStyle(Theme.primary)
                        // Same `.monotone` fix as above.
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: xAxisTickDates) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartXScale(domain: xAxisDomain)
                .chartYScale(domain: yAxisDomain)
                .frame(height: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Medication level estimate")
                .accessibilityValue(trendDescription)

                // Explicit "not for timing your dose" framing directly on the card, not
                // just one tap away in the citation sheet — this is the app's newest
                // health-derived computation, and the existing titration feature's own
                // residual-risk note (APP_REVIEW_NOTES.md §5, Guideline 1.4.1's
                // dosage-calculator clause) is the reason this line exists at all: it
                // should be unambiguous on sight that this chart never calculates,
                // suggests, or times a dose.
                // Caught 2026-08-03 while completing Spanish translation
                // coverage: `"entered"`/`"published"` were plain Swift
                // string literals interpolated directly into this Text,
                // bypassing localization entirely — even with the
                // surrounding sentence translated, a Spanish-language user
                // would still see the literal English word "entered" or
                // "published" sitting in the middle of it. `String(localized:)`
                // gives each word its own catalog entry so it picks up a
                // real Spanish translation like everything else here.
                Text("Estimate from your logged doses and \(resolvedName)'s \(customHalfLifeHours != nil ? String(localized: "entered") : String(localized: "published")) half-life, not a real blood measurement, and never a basis for deciding when to take your next dose.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !weightOverlayPoints.isEmpty {
                    Text("Weight is rescaled to line up visually with the level estimate above, for shape comparison only, not a real overlay of values.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !projectedPoints.isEmpty {
                    Text(projectionIncludesUpcomingDose
                        ? "The dashed section is a projection assuming your next dose happens exactly as scheduled. It's a forward extension of the same estimate above, not a prediction, and never a reason to change your schedule."
                        : "The dashed section projects forward from your logged doses only, with no further doses assumed. It's a forward extension of the same estimate above, not a prediction, and never a reason to change your schedule.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Log a dose to see your estimated medication level")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var unavailableState: some View {
        Text("Not available for \(resolvedName): no half-life is set for this medication.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    let calendar = Calendar.current
    let logs = [0, 7, 14, 21].map { daysAgo in
        DoseLog(
            date: calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now,
            doseMg: 1.0, form: .injection
        )
    }
    let weights = (0..<22).map { daysAgo in
        WeightEntry(
            date: calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now,
            weightLbs: 200 - Double(21 - daysAgo) * 0.4
        )
    }
    return MedicationLevelCard(medication: .ozempic, doseLogs: logs, weightEntries: weights)
        .padding()
}
