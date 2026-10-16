import XCTest
@testable import Sustain

final class DoseFrequencyTests: XCTestCase {
    func testWeekly_nextDueDateAddsSevenDays() {
        let lastDose = Date.now
        let expected = Calendar.current.date(byAdding: .day, value: 7, to: lastDose)!
        XCTAssertEqual(DoseFrequency.weekly.nextDueDate(after: lastDose), expected)
    }

    func testDaily_nextDueDateAddsOneDay() {
        let lastDose = Date.now
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: lastDose)!
        XCTAssertEqual(DoseFrequency.daily.nextDueDate(after: lastDose), expected)
    }

    // MARK: - .specificDays (2026-08-01, explicit request: exact-days schedules
    // like Mon/Wed/Fri for a compounded/custom program)

    func testSpecificDays_findsTheNextMatchingWeekday() {
        let calendar = Calendar.current
        // A known Sunday (weekday 1): Jan 4, 2026.
        var components = DateComponents(year: 2026, month: 1, day: 4)
        let sunday = calendar.date(from: components)!
        XCTAssertEqual(calendar.component(.weekday, from: sunday), 1)

        // Scheduled for Mon/Wed/Fri (2, 4, 6) — the next one after a Sunday
        // dose should be Monday, exactly one day later.
        let next = DoseFrequency.specificDays.nextDueDate(after: sunday, scheduledWeekdays: [2, 4, 6], calendar: calendar)
        components = DateComponents(year: 2026, month: 1, day: 5)
        XCTAssertEqual(calendar.startOfDay(for: next), calendar.date(from: components)!)
    }

    func testSpecificDays_skipsAheadPastUnscheduledDays() {
        let calendar = Calendar.current
        // A known Monday (weekday 2): Jan 5, 2026.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)

        // Scheduled only for Friday (6) — from a Monday dose, the next one
        // should skip Tue/Wed/Thu and land on that same week's Friday.
        let next = DoseFrequency.specificDays.nextDueDate(after: monday, scheduledWeekdays: [6], calendar: calendar)
        let expectedFriday = calendar.date(from: DateComponents(year: 2026, month: 1, day: 9))!
        XCTAssertEqual(calendar.startOfDay(for: next), expectedFriday)
    }

    func testSpecificDays_fallsBackToTomorrowWithNoSelectedDays() {
        let lastDose = Date.now
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: lastDose)!
        XCTAssertEqual(DoseFrequency.specificDays.nextDueDate(after: lastDose, scheduledWeekdays: []), expected)
    }
}

final class WeightUnitTests: XCTestCase {
    func testConvertPoundsToKilograms() {
        // 220 lb ≈ 99.79 kg
        let result = WeightUnit.pounds.convert(220, to: .kilograms)
        XCTAssertEqual(result, 99.79, accuracy: 0.01)
    }

    func testConvertKilogramsToPounds() {
        // 100 kg ≈ 220.46 lb
        let result = WeightUnit.kilograms.convert(100, to: .pounds)
        XCTAssertEqual(result, 220.46, accuracy: 0.01)
    }

    func testConvertSameUnitReturnsSameValue() {
        XCTAssertEqual(WeightUnit.pounds.convert(180, to: .pounds), 180)
        XCTAssertEqual(WeightUnit.kilograms.convert(80, to: .kilograms), 80)
    }

    func testRoundTripConversionIsLossless() {
        let original = 165.4
        let roundTripped = WeightUnit.kilograms.convert(WeightUnit.pounds.convert(original, to: .kilograms), to: .pounds)
        XCTAssertEqual(roundTripped, original, accuracy: 0.0001)
    }
}
