import XCTest
@testable import Sustain

final class MedicationProfileTests: XCTestCase {

    private func makeProfile(
        targetWeightLbs: Double? = nil,
        startingWeightLbs: Double? = nil
    ) -> MedicationProfile {
        MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5,
            startingWeightLbs: startingWeightLbs, targetWeightLbs: targetWeightLbs
        )
    }

    // MARK: - dailyProteinGoalGrams

    func testDailyProteinGoalGrams_usesTargetWeightWhenSet() {
        let profile = makeProfile(targetWeightLbs: 150, startingWeightLbs: 200)
        XCTAssertEqual(profile.dailyProteinGoalGrams(fallbackWeightLbs: 999), 120) // 150 * 0.8
    }

    func testDailyProteinGoalGrams_fallsBackToStartingWeightWhenNoTarget() {
        let profile = makeProfile(startingWeightLbs: 190)
        XCTAssertEqual(profile.dailyProteinGoalGrams(fallbackWeightLbs: 999), 152) // 190 * 0.8
    }

    func testDailyProteinGoalGrams_fallsBackToProvidedWeightWhenNeitherSet() {
        let profile = makeProfile()
        XCTAssertEqual(profile.dailyProteinGoalGrams(fallbackWeightLbs: 180), 144) // 180 * 0.8
    }

    // MARK: - Titration plan

    func testHasPendingTitration_falseWhenNeitherFieldSet() {
        let profile = makeProfile()
        XCTAssertFalse(profile.hasPendingTitration)
    }

    func testHasPendingTitration_trueOnlyWhenBothDoseAndDateSet() {
        let profile = makeProfile()
        profile.plannedNextDoseMg = 7.5
        XCTAssertFalse(profile.hasPendingTitration, "A dose with no date isn't a real plan yet")

        profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: 14, to: .now)
        XCTAssertTrue(profile.hasPendingTitration)
    }

    func testIsTitrationDue_falseForFutureDate() {
        let profile = makeProfile()
        profile.plannedNextDoseMg = 7.5
        profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: 5, to: .now)
        XCTAssertFalse(profile.isTitrationDue)
    }

    func testIsTitrationDue_trueForPastDate() {
        let profile = makeProfile()
        profile.plannedNextDoseMg = 7.5
        profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: -1, to: .now)
        XCTAssertTrue(profile.isTitrationDue)
    }

    func testApplyPlannedTitration_commitsNewDoseAndClearsPlan() {
        let profile = makeProfile()
        profile.plannedNextDoseMg = 7.5
        profile.plannedDoseChangeDate = Calendar.current.date(byAdding: .day, value: -1, to: .now)

        profile.applyPlannedTitration()

        XCTAssertEqual(profile.currentDoseMg, 7.5)
        XCTAssertNil(profile.plannedNextDoseMg)
        XCTAssertNil(profile.plannedDoseChangeDate)
        XCTAssertFalse(profile.hasPendingTitration)
    }

    func testApplyPlannedTitration_noOpWhenNoPlanSet() {
        let profile = makeProfile()
        profile.applyPlannedTitration()
        XCTAssertEqual(profile.currentDoseMg, 5)
    }

    // MARK: - hasStartedMedication

    func testHasStartedMedication_defaultsToTrue() {
        // Every normal onboarding/edit path relies on this default — only the
        // "I haven't started yet" onboarding path explicitly passes `false`.
        XCTAssertTrue(makeProfile().hasStartedMedication)
    }

    func testHasStartedMedication_canBeCreatedFalse() {
        let profile = MedicationProfile(
            medication: .rybelsus, form: .oralPill, frequency: .daily, startDate: .now,
            currentDoseMg: 0, hasStartedMedication: false
        )
        XCTAssertFalse(profile.hasStartedMedication)
    }

    // MARK: - scheduledWeekdays (2026-08-01, specific-days schedules)

    func testScheduledWeekdays_defaultsToEmpty() {
        XCTAssertEqual(makeProfile().scheduledWeekdays, [])
    }

    func testScheduledWeekdays_roundTripsThroughRawStorage() {
        let profile = MedicationProfile(
            medication: .compounded, form: .injection, frequency: .specificDays, startDate: .now,
            currentDoseMg: 1, scheduledWeekdays: [6, 2, 4]
        )
        // Order shouldn't matter for equality (it's a Set), but the raw
        // storage underneath is sorted for a stable, human-readable synced
        // value — see `MedicationProfile.scheduledWeekdaysRaw`.
        XCTAssertEqual(profile.scheduledWeekdays, [2, 4, 6])
        XCTAssertEqual(profile.scheduledWeekdaysRaw, "2,4,6")

        profile.scheduledWeekdays = [7]
        XCTAssertEqual(profile.scheduledWeekdaysRaw, "7")
        XCTAssertEqual(profile.scheduledWeekdays, [7])
    }
}
