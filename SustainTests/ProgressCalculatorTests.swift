import XCTest
@testable import Sustain

/// `ProgressCalculator` was deliberately written pure/stateless so its math could be
/// tested independently of SwiftData or the network — this is that test target,
/// previously nonexistent (README item 7, "no test target yet").
final class ProgressCalculatorTests: XCTestCase {

    // MARK: - todaysTotal

    func testTodaysTotal_sumsOnlyTodaysEntries() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let entries = [
            ProteinEntry(date: .now, grams: 20),
            ProteinEntry(date: .now, grams: 15),
            ProteinEntry(date: yesterday, grams: 100),
        ]
        XCTAssertEqual(ProgressCalculator.todaysTotal(entries), 35)
    }

    func testTodaysTotal_zeroWhenNoEntries() {
        XCTAssertEqual(ProgressCalculator.todaysTotal([]), 0)
    }

    // MARK: - weightChange

    func testWeightChange_nilWithFewerThanTwoEntries() {
        XCTAssertNil(ProgressCalculator.weightChange([]))
        XCTAssertNil(ProgressCalculator.weightChange([WeightEntry(date: .now, weightLbs: 180)]))
    }

    func testWeightChange_computesNegativeForWeightLoss() {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -30, to: .now)!
        let entries = [
            WeightEntry(date: start, weightLbs: 200),
            WeightEntry(date: .now, weightLbs: 190),
        ]
        XCTAssertEqual(ProgressCalculator.weightChange(entries), -10)
    }

    func testWeightChange_sortsByDateRegardlessOfInputOrder() {
        let calendar = Calendar.current
        let earlier = calendar.date(byAdding: .day, value: -10, to: .now)!
        // Deliberately passed out of chronological order — the function must sort,
        // not assume the caller already did.
        let entries = [
            WeightEntry(date: .now, weightLbs: 175),
            WeightEntry(date: earlier, weightLbs: 180),
        ]
        XCTAssertEqual(ProgressCalculator.weightChange(entries), -5)
    }

    // MARK: - lastDose

    func testLastDose_ignoresSkippedDoses() {
        let calendar = Calendar.current
        let earlier = calendar.date(byAdding: .day, value: -7, to: .now)!
        let logs = [
            DoseLog(date: earlier, doseMg: 5, form: .injection, skipped: false),
            DoseLog(date: .now, doseMg: 5, form: .injection, skipped: true),
        ]
        XCTAssertEqual(ProgressCalculator.lastDose(logs)?.date, earlier)
    }

    func testLastDose_nilWhenEmptyOrAllSkipped() {
        XCTAssertNil(ProgressCalculator.lastDose([]))
        XCTAssertNil(ProgressCalculator.lastDose([DoseLog(date: .now, doseMg: 5, form: .injection, skipped: true)]))
    }

    // MARK: - nextDoseDate

    func testNextDoseDate_anchorsOnLastDoseWhenPresent() {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -60, to: .now)!
        let lastDoseDate = calendar.date(byAdding: .day, value: -3, to: .now)!
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: startDate, currentDoseMg: 5
        )
        let logs = [DoseLog(date: lastDoseDate, doseMg: 5, form: .injection)]

        let expected = calendar.date(byAdding: .day, value: 7, to: lastDoseDate)!
        XCTAssertEqual(
            calendar.compare(ProgressCalculator.nextDoseDate(profile: profile, logs: logs), to: expected, toGranularity: .minute),
            .orderedSame
        )
    }

    func testNextDoseDate_fallsBackToProfileStartDateWhenNoLogs() {
        let startDate = Date.now
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: startDate, currentDoseMg: 5
        )
        let expected = Calendar.current.date(byAdding: .day, value: 7, to: startDate)!
        XCTAssertEqual(
            Calendar.current.compare(ProgressCalculator.nextDoseDate(profile: profile, logs: []), to: expected, toGranularity: .minute),
            .orderedSame
        )
    }

    // MARK: - weeklySummaryInput

    func testWeeklySummaryInput_countsLoggedAndSkippedDosesSeparately() {
        let calendar = Calendar.current
        let profile = MedicationProfile(
            medication: .rybelsus, form: .oralPill, frequency: .daily, startDate: .now, currentDoseMg: 7
        )
        let doseLogs = [
            DoseLog(date: .now, doseMg: 7, form: .oralPill, skipped: false),
            DoseLog(date: calendar.date(byAdding: .day, value: -1, to: .now)!, doseMg: 7, form: .oralPill, skipped: false),
            DoseLog(date: calendar.date(byAdding: .day, value: -2, to: .now)!, doseMg: 7, form: .oralPill, skipped: true),
        ]

        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: doseLogs, weightEntries: [], proteinEntries: [], sideEffectLogs: []
        )

        XCTAssertEqual(input.dosesLogged, 2)
        XCTAssertEqual(input.dosesSkipped, 1)
        XCTAssertEqual(input.dosesExpected, 7) // daily frequency
    }

    func testWeeklySummaryInput_dosesExpectedMatchesScheduledWeekdayCount() {
        let profile = MedicationProfile(
            medication: .compounded, form: .injection, frequency: .specificDays, startDate: .now, currentDoseMg: 1,
            scheduledWeekdays: [2, 4, 6] // Mon/Wed/Fri
        )
        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: [], weightEntries: [], proteinEntries: [], sideEffectLogs: []
        )
        XCTAssertEqual(input.dosesExpected, 3)
    }

    func testWeeklySummaryInput_weightChangeNilWithFewerThanTwoWeighIns() {
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: [], weightEntries: [WeightEntry(date: .now, weightLbs: 180)],
            proteinEntries: [], sideEffectLogs: []
        )
        XCTAssertNil(input.weightChangeLbs)
    }

    func testWeeklySummaryInput_topSideEffectsSortedByCountAndCappedAtThree() {
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
        let sideEffects = [
            SideEffectLog(date: .now, symptom: .nausea, severity: 2),
            SideEffectLog(date: .now, symptom: .nausea, severity: 3),
            SideEffectLog(date: .now, symptom: .fatigue, severity: 4),
            SideEffectLog(date: .now, symptom: .headache, severity: 1),
            SideEffectLog(date: .now, symptom: .dizziness, severity: 2),
        ]

        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: [], weightEntries: [], proteinEntries: [], sideEffectLogs: sideEffects
        )

        XCTAssertEqual(input.topSideEffects.count, 3)
        XCTAssertEqual(input.topSideEffects.first?.symptom, SideEffectSymptom.nausea.displayName)
        XCTAssertEqual(input.topSideEffects.first?.count, 2)
    }

    /// A brand-new profile (started today) shouldn't have its average diluted by
    /// days before it existed. Previously this always divided by a hardcoded 7, so
    /// 100g logged today on a same-day profile read as ~14g/day instead of 100g/day.
    func testWeeklySummaryInput_averageProteinDividesByProfileTenureNotFixedSeven() {
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: [], weightEntries: [],
            proteinEntries: [ProteinEntry(date: .now, grams: 100)], sideEffectLogs: []
        )
        XCTAssertEqual(input.averageDailyProteinGrams, 100)
    }

    /// Once a profile is a week or older, the tenure-based divisor collapses back
    /// to exactly 7 — this fix changes nothing for the common long-term case.
    func testWeeklySummaryInput_averageProteinStillDividesBySevenForOlderProfiles() {
        let calendar = Calendar.current
        let profile = MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly,
            startDate: calendar.date(byAdding: .day, value: -30, to: .now)!, currentDoseMg: 5
        )
        let input = ProgressCalculator.weeklySummaryInput(
            profile: profile, doseLogs: [], weightEntries: [],
            proteinEntries: [ProteinEntry(date: .now, grams: 700)], sideEffectLogs: []
        )
        XCTAssertEqual(input.averageDailyProteinGrams, 100)
    }

    // MARK: - plateauMessage

    func testPlateauMessage_nilWithFewerThanThreeEntries() {
        let calendar = Calendar.current
        let entries = [
            WeightEntry(date: calendar.date(byAdding: .day, value: -20, to: .now)!, weightLbs: 180),
            WeightEntry(date: .now, weightLbs: 179.5),
        ]
        XCTAssertNil(ProgressCalculator.plateauMessage(weightEntries: entries))
    }

    func testPlateauMessage_nilWhenWindowSpansFewerThanFourteenDays() {
        let calendar = Calendar.current
        // Three entries, but all bunched within a week — not enough of a stretch to
        // distinguish a real plateau from ordinary short-term fluctuation.
        let entries = [
            WeightEntry(date: calendar.date(byAdding: .day, value: -6, to: .now)!, weightLbs: 180),
            WeightEntry(date: calendar.date(byAdding: .day, value: -3, to: .now)!, weightLbs: 179.8),
            WeightEntry(date: .now, weightLbs: 179.9),
        ]
        XCTAssertNil(ProgressCalculator.plateauMessage(weightEntries: entries))
    }

    func testPlateauMessage_detectsGenuinePlateau() {
        let calendar = Calendar.current
        // A fixed `asOf` — captured once and passed explicitly to both the test
        // data and the function call — is what actually matters here, not the day
        // offsets themselves. Building entries off a bare `.now` and letting
        // `plateauMessage` default `asOf` to its *own*, separately-evaluated `.now`
        // put the earliest entry a few milliseconds before the function's computed
        // window start, silently excluding it right at the boundary.
        let now = Date()
        let entries = [
            WeightEntry(date: calendar.date(byAdding: .day, value: -21, to: now)!, weightLbs: 180),
            WeightEntry(date: calendar.date(byAdding: .day, value: -10, to: now)!, weightLbs: 179.6),
            WeightEntry(date: now, weightLbs: 179.8),
        ]
        XCTAssertNotNil(ProgressCalculator.plateauMessage(weightEntries: entries, asOf: now))
    }

    func testPlateauMessage_nilDuringActiveWeightLoss() {
        let calendar = Calendar.current
        let now = Date()
        let entries = [
            WeightEntry(date: calendar.date(byAdding: .day, value: -21, to: now)!, weightLbs: 200),
            WeightEntry(date: calendar.date(byAdding: .day, value: -10, to: now)!, weightLbs: 194),
            WeightEntry(date: now, weightLbs: 188),
        ]
        XCTAssertNil(ProgressCalculator.plateauMessage(weightEntries: entries, asOf: now))
    }

    func testPlateauMessage_thresholdScalesWithBodyWeight() {
        let calendar = Calendar.current
        let now = Date()
        // 1.3 lbs of net movement over three weeks passes either way for a 250 lb
        // starting weight (flat floor is 2 lbs, 1% of 250 is 2.5 lbs) — this just
        // locks in that the percentage-of-weight side of the threshold produces a
        // sensible, wider allowance at a higher starting weight, not just the floor.
        let entries = [
            WeightEntry(date: calendar.date(byAdding: .day, value: -21, to: now)!, weightLbs: 250),
            WeightEntry(date: calendar.date(byAdding: .day, value: -10, to: now)!, weightLbs: 249.2),
            WeightEntry(date: now, weightLbs: 248.7),
        ]
        XCTAssertNotNil(ProgressCalculator.plateauMessage(weightEntries: entries, asOf: now))
    }

    // MARK: - proteinGoalStreak

    func testProteinGoalStreak_zeroWithNoEntries() {
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: [], goalGrams: 120), 0)
    }

    func testProteinGoalStreak_countsTodayWhenGoalAlreadyMet() {
        let now = Date()
        let entries = [ProteinEntry(date: now, grams: 130)]
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: entries, goalGrams: 120, asOf: now), 1)
    }

    func testProteinGoalStreak_doesNotCountTodayBeforeGoalIsMetYet() {
        // Today's total is under goal, but the day isn't over yet — this should
        // read as "streak not yet broken," not "streak already reset to zero,"
        // which is why yesterday's met goal still counts.
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let entries = [
            ProteinEntry(date: yesterday, grams: 130),
            ProteinEntry(date: now, grams: 20),
        ]
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: entries, goalGrams: 120, asOf: now), 1)
    }

    func testProteinGoalStreak_countsConsecutiveDaysAndStopsAtFirstMiss() {
        let calendar = Calendar.current
        let now = Date()
        let entries = [
            ProteinEntry(date: now, grams: 130),
            ProteinEntry(date: calendar.date(byAdding: .day, value: -1, to: now)!, grams: 125),
            ProteinEntry(date: calendar.date(byAdding: .day, value: -2, to: now)!, grams: 121),
            // Breaks the streak three days back.
            ProteinEntry(date: calendar.date(byAdding: .day, value: -3, to: now)!, grams: 40),
            ProteinEntry(date: calendar.date(byAdding: .day, value: -4, to: now)!, grams: 150),
        ]
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: entries, goalGrams: 120, asOf: now), 3)
    }

    func testProteinGoalStreak_sumsMultipleEntriesPerDay() {
        let now = Date()
        let entries = [
            ProteinEntry(date: now, grams: 60),
            ProteinEntry(date: now, grams: 65),
        ]
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: entries, goalGrams: 120, asOf: now), 1)
    }

    func testProteinGoalStreak_zeroWhenGoalIsZeroOrNegative() {
        let entries = [ProteinEntry(date: .now, grams: 100)]
        XCTAssertEqual(ProgressCalculator.proteinGoalStreak(proteinEntries: entries, goalGrams: 0), 0)
    }
}
