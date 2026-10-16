import XCTest
@testable import Sustain

final class MedicationLevelCalculatorTests: XCTestCase {

    func testRelativeLevelSeries_emptyForMedicationWithNoKnownHalfLife() {
        let logs = [DoseLog(date: .now, doseMg: 2.5, form: .injection)]
        XCTAssertTrue(MedicationLevelCalculator.relativeLevelSeries(medication: .compounded, doseLogs: logs).isEmpty)
        XCTAssertTrue(MedicationLevelCalculator.relativeLevelSeries(medication: .other, doseLogs: logs).isEmpty)
    }

    func testRelativeLevelSeries_emptyWithNoDoses() {
        XCTAssertTrue(MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: []).isEmpty)
    }

    func testRelativeLevelSeries_ignoresSkippedDoses() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let skippedOnly = [DoseLog(date: asOf, doseMg: 1.0, form: .injection, skipped: true)]
        XCTAssertTrue(
            MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: skippedOnly, asOf: asOf).isEmpty
        )
    }

    func testRelativeLevelSeries_levelIsZeroBeforeFirstDose() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        let doseDate = calendar.date(byAdding: .day, value: -1, to: asOf)!
        let logs = [DoseLog(date: doseDate, doseMg: 1.0, form: .injection)]
        let points = MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: logs, days: 10, asOf: asOf)

        // Points more than a day before the single dose must read exactly 0 —
        // nothing has been taken yet.
        let earliestPoint = points.first!
        XCTAssertEqual(earliestPoint.relativeLevel, 0, accuracy: 0.0001)
    }

    func testRelativeLevelSeries_decaysMonotonicallyAfterASingleDose() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        // 5 days clear of the 20-day display window's own start, regardless of
        // what time of day `asOf` happens to fall at — guarantees the dose is
        // already decaying throughout the entire displayed window, with no
        // zero-then-jump artifact from the dose landing partway into day one.
        let doseDate = calendar.date(byAdding: .day, value: -25, to: asOf)!
        let logs = [DoseLog(date: doseDate, doseMg: 1.0, form: .injection)]
        let points = MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: logs, days: 20, asOf: asOf)

        // Semaglutide's ~7-day half-life means a single dose taken well before
        // this window starts should be monotonically decaying throughout — every
        // point should be less than or equal to the one before it.
        for (previous, current) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(current.relativeLevel, previous.relativeLevel + 0.0001)
        }
    }

    func testRelativeLevelSeries_secondDoseRaisesLevelAboveWhatFirstAloneWouldGive() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        let firstDose = calendar.date(byAdding: .day, value: -7, to: asOf)!
        let secondDose = asOf

        let oneDoseOnly = [DoseLog(date: firstDose, doseMg: 1.0, form: .injection)]
        let twoDoses = oneDoseOnly + [DoseLog(date: secondDose, doseMg: 1.0, form: .injection)]

        let levelWithOneDose = MedicationLevelCalculator.relativeLevelSeries(
            medication: .ozempic, doseLogs: oneDoseOnly, days: 1, asOf: asOf
        ).last!.relativeLevel
        let levelWithTwoDoses = MedicationLevelCalculator.relativeLevelSeries(
            medication: .ozempic, doseLogs: twoDoses, days: 1, asOf: asOf
        ).last!.relativeLevel

        // Superimposing a second dose must never produce a *lower* estimated
        // level than the first dose alone would have given at the same moment.
        XCTAssertGreaterThan(levelWithTwoDoses, levelWithOneDose)
    }

    func testRelativeLevelSeries_pointCountMatchesRequestedWindowPlusToday() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        // Dose predates the 14-day window entirely (an established user, not
        // someone who just started) so the window-clamping fix below doesn't
        // shrink it — this test is specifically about the requested window
        // size, not the clamping behavior, which has its own test.
        let doseDate = calendar.date(byAdding: .day, value: -20, to: asOf)!
        let logs = [DoseLog(date: doseDate, doseMg: 1.0, form: .injection)]
        let points = MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: logs, days: 14, asOf: asOf)
        // 14 days back through today, inclusive, is 15 daily points.
        XCTAssertEqual(points.count, 15)
    }

    // Real UX bug, caught from a screenshot: a brand-new user with a single
    // dose logged today used to get a chart padded with weeks of fabricated
    // zero-level days before it (from the fixed `days`-wide window reaching
    // back before any dose existed), reading as a flat line that suddenly
    // spikes rather than "day one." The window now clamps to whichever is
    // later — the requested window, or the day of the earliest logged
    // dose — so someone who started today sees a chart that actually starts
    // today, not 14 days of nothing.
    func testRelativeLevelSeries_clampsWindowToFirstDoseForNewUsers() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let logs = [DoseLog(date: asOf, doseMg: 1.0, form: .injection)]
        let points = MedicationLevelCalculator.relativeLevelSeries(medication: .ozempic, doseLogs: logs, days: 14, asOf: asOf)
        // Without the clamp this would be 15 (the full requested window) —
        // the whole point of the fix is that a same-day first dose collapses
        // this down to just today's point instead.
        XCTAssertEqual(points.count, 1)
    }
}
