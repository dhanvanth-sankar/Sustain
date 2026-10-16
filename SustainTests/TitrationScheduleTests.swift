import XCTest
@testable import Sustain

final class TitrationScheduleTests: XCTestCase {

    // MARK: - nextStep

    func testNextStep_returnsNextRungForKnownMedicationAndDose() {
        let step = TitrationSchedule.nextStep(for: .zepbound, form: .injection, currentDoseMg: 5.0)
        XCTAssertEqual(step?.doseMg, 7.5)
    }

    func testNextStep_matchesDoseWithinFloatingPointTolerance() {
        // Guards against a manual-entry value like "1.70" failing to match the
        // ladder's "1.7" rung due to naive floating-point equality — if "1.70"
        // didn't match at all, this would return nil instead of the step that
        // actually follows "1.7" on the Wegovy injection ladder (2.4, the final
        // maintenance dose).
        let step = TitrationSchedule.nextStep(for: .wegovy, form: .injection, currentDoseMg: 1.70)
        XCTAssertEqual(step?.doseMg, 2.4)
    }

    func testNextStep_nilAtTopOfLadder() {
        // 2.4 mg is the final Wegovy injection maintenance dose — nothing further
        // to suggest.
        XCTAssertNil(TitrationSchedule.nextStep(for: .wegovy, form: .injection, currentDoseMg: 2.4))
    }

    func testNextStep_nilForUnmatchedDose() {
        // 4 mg doesn't correspond to any real Zepbound rung.
        XCTAssertNil(TitrationSchedule.nextStep(for: .zepbound, form: .injection, currentDoseMg: 4.0))
    }

    func testNextStep_nilForMedicationWithNoStandardLadder() {
        XCTAssertNil(TitrationSchedule.nextStep(for: .compounded, form: .injection, currentDoseMg: 2.5))
        XCTAssertNil(TitrationSchedule.nextStep(for: .other, form: .injection, currentDoseMg: 2.5))
    }

    func testNextStep_rybelsusUsesOralDoseLadder() {
        let step = TitrationSchedule.nextStep(for: .rybelsus, form: .oralPill, currentDoseMg: 3.0)
        XCTAssertEqual(step?.doseMg, 7.0)
    }

    // Wegovy is the one medication with two real FDA-approved forms with
    // genuinely different ladders (the 02/2026-revised label added an oral
    // tablet alongside the pre-existing weekly injection) — these lock in that
    // the two don't get confused with each other now that lookups are keyed by
    // (medication, form) instead of medication alone.
    func testNextStep_wegovyOralUsesTabletDoseLadder_distinctFromInjection() {
        let step = TitrationSchedule.nextStep(for: .wegovy, form: .oralPill, currentDoseMg: 1.5)
        XCTAssertEqual(step?.doseMg, 4.0)
    }

    func testNextStep_wegovyOralTopOfLadderIs25mg() {
        XCTAssertNil(TitrationSchedule.nextStep(for: .wegovy, form: .oralPill, currentDoseMg: 25.0))
    }

    func testNextStep_wegovyOralDoseDoesNotMatchInjectionLadder() {
        // 1.7 mg is a real rung on the Wegovy *injection* ladder but not on the
        // oral ladder (1.5/4/9/25) — must not silently fall through to the wrong
        // form's schedule.
        XCTAssertNil(TitrationSchedule.nextStep(for: .wegovy, form: .oralPill, currentDoseMg: 1.7))
    }

    func testNextStep_nilForMedicationFormCombinationWithNoRealProduct() {
        // No real Ozempic oral product exists — the form picker doesn't prevent
        // selecting this combination, but the schedule lookup must not guess.
        XCTAssertNil(TitrationSchedule.nextStep(for: .ozempic, form: .oralPill, currentDoseMg: 0.25))
    }

    // MARK: - weeksUntilNextStep

    func testWeeksUntilNextStep_matchesLadderInterval() {
        // Zepbound/Mounjaro-style ladders step every 4 weeks.
        XCTAssertEqual(TitrationSchedule.weeksUntilNextStep(for: .zepbound, form: .injection, currentDoseMg: 2.5), 4)
        // Saxenda steps up weekly, much faster than the injectable semaglutide/
        // tirzepatide ladders above — this is what actually distinguishes the two,
        // not just the dose numbers.
        XCTAssertEqual(TitrationSchedule.weeksUntilNextStep(for: .saxenda, form: .injection, currentDoseMg: 0.6), 1)
    }

    func testWeeksUntilNextStep_wegovyOralStepsEvery4Weeks() {
        // Oral Wegovy titrates every 30 days, modeled as 4 weeks — the same
        // convention already used for Rybelsus's own 30-day cadence.
        XCTAssertEqual(TitrationSchedule.weeksUntilNextStep(for: .wegovy, form: .oralPill, currentDoseMg: 4.0), 4)
    }

    func testWeeksUntilNextStep_nilWhenNextStepIsNil() {
        XCTAssertNil(TitrationSchedule.weeksUntilNextStep(for: .wegovy, form: .injection, currentDoseMg: 2.4))
        XCTAssertNil(TitrationSchedule.weeksUntilNextStep(for: .other, form: .injection, currentDoseMg: 5))
    }
}
