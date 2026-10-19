//
//  MacroCalorieIdentityTests.swift
//  TheJymTests
//
//  The Cycle macro section shows "Cycle 1 · 2450" in its header and a
//  calorie target of 2455 six rows below it, and to anyone who doesn't
//  know why, that looks like a bug.
//
//  It isn't. 2450 is the tier's NAME — free text that happens to look
//  like a calorie figure, because that is how diet tiers get named. 2455
//  is what the tier's macros actually cost: 4*185 + 4*260 + 9*75. Nothing
//  rounds the grams to make the label come true.
//
//  The obvious "fix" is to source the target from the name and make the
//  two agree. That would measure a cycle against a string, and would
//  silently stop tracking the first time a gram value was edited without
//  renaming the tier. These tests exist to stop that happening at 3am.
//
//  The value identity (calories == 4P + 4C + 9F of the means) is gated,
//  because it is only true when the day sets coincide — see
//  CalorieAverage for why calories use a stricter basis. The gate is
//  itself asserted: the non-uniform case checks that the identity
//  genuinely FAILS there, so the gate is load-bearing rather than a
//  silent escape hatch.
//
//  Sabotage: in MacroCycleSummary.compute, pass
//  `calorieTarget: Double(tier.name) ?? tier.calories` and
//  testTheCalorieTargetIsCostedFromMacrosNotTheTierName fails.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class MacroCalorieIdentityTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var anchor = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: anchor)! }

    /// Named "2450" on purpose, with macros that cost 2455 — the exact
    /// mismatch the real store has, so the test fixture carries the
    /// confusing case rather than a tidied-up one.
    private static let tierName = "2450"
    private static let protein = 185.0, carbs = 260.0, fat = 75.0

    private func summary(logs: [MacroLog], days: Int) -> MacroCycleSummary? {
        let c = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        let phase = Phase(number: 1, totalCycles: 4, startDate: day(0), isActive: true)
        ctx.insert(phase)
        for (i, name) in ["Push", "Pull", "Rest"].enumerated() {
            let d = PhaseDay(order: i, name: name, isRest: name == "Rest")
            d.phase = phase
            ctx.insert(d)
        }
        let trainingDay = phase.orderedDays.first { !$0.isRest }
        for i in 0..<days {
            let s = WorkoutSession(date: day(i), dayLabel: "Push", cycleNumber: 1)
            s.phase = phase
            s.day = trainingDay
            ctx.insert(s)
            let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
            log.session = s
            ctx.insert(log)
        }
        let tier = MacroTier(name: Self.tierName, order: 0,
                             proteinGrams: Self.protein, carbsGrams: Self.carbs,
                             fatGrams: Self.fat, sugarGrams: 90, fiberGrams: 36)
        ctx.insert(tier)
        ctx.insert(CycleMacroTag(cycleNumber: 1, phase: phase, tier: tier))
        for l in logs { ctx.insert(l) }
        return MacroCycleSummary.compute(phase: phase, cycle: 1, logs: logs, now: day(days))
    }

    /// The real store's three days, so the numbers here are the ones on
    /// screen rather than invented ones.
    private var realDays: [MacroLog] {
        [MacroLog(date: day(0), proteinGrams: 185, carbsGrams: 248, fatGrams: 66,
                  sugarGrams: 20, fiberGrams: 57),
         MacroLog(date: day(1), proteinGrams: 207, carbsGrams: 198, fatGrams: 91,
                  sugarGrams: 78, fiberGrams: 23),
         MacroLog(date: day(2), proteinGrams: 170, carbsGrams: 237, fatGrams: 90,
                  sugarGrams: 95, fiberGrams: 25)]
    }

    // MARK: - The target

    func testTheCalorieTargetIsCostedFromMacrosNotTheTierName() throws {
        let s = try XCTUnwrap(summary(logs: realDays, days: 3))
        let costed = 4 * Self.protein + 4 * Self.carbs + 9 * Self.fat
        XCTAssertEqual(costed, 2455, "sanity: this fixture's macros cost 2455")
        XCTAssertEqual(s.calorieTarget, costed, accuracy: 1e-9,
                       "the target must be 4P + 4C + 9F of the tier's grams")

        let fromName = try XCTUnwrap(Double(s.tier.name))
        XCTAssertEqual(fromName, 2450, "sanity: this fixture's tier is named 2450")
        XCTAssertNotEqual(s.calorieTarget, fromName,
                          "The header's \"\(s.tier.name)\" and this target are DIFFERENT NUMBERS "
                          + "and that is correct — the name is a label, the target is the macros "
                          + "costed. Making them agree by reading the name would measure the "
                          + "cycle against a string. See MacroVariance.swift's note.")
    }

    /// Renaming the tier must not move the target by a single calorie.
    func testRenamingTheTierDoesNotMoveTheTarget() throws {
        let s = try XCTUnwrap(summary(logs: realDays, days: 3))
        let before = s.calorieTarget
        s.tier.name = "1200"
        XCTAssertEqual(s.calorieTarget, before, accuracy: 1e-9)
    }

    // MARK: - The value, gated

    func testTheCalorieValueIsTheMacroIdentityWhenDaySetsAreUniform() throws {
        let s = try XCTUnwrap(summary(logs: realDays, days: 3))
        XCTAssertTrue(s.dayCountsAreUniform, "this fixture logs every category every day")

        let p = try XCTUnwrap(s.variances.first { $0.category == .protein }.flatMap(\.average.mean))
        let c = try XCTUnwrap(s.variances.first { $0.category == .carbs }.flatMap(\.average.mean))
        let f = try XCTUnwrap(s.variances.first { $0.category == .fat }.flatMap(\.average.mean))
        let mean = try XCTUnwrap(s.calories.mean)

        XCTAssertEqual(4 * p + 4 * c + 9 * f, mean, accuracy: 1e-6,
                       "with one shared day set, the calorie row IS the macro rows costed")
        // And the figures that reach the screen agree too, which is the
        // check a reader can do by hand.
        XCTAssertEqual(MacroFigure.value(mean, unit: ""), "2401")
        XCTAssertEqual(MacroFigure.target(s.calorieTarget), "2455")
        XCTAssertEqual(MacroFigure.delta(s.calorieDelta), "-54")
    }

    /// THE GATE, asserted rather than assumed. With one day's fat
    /// missing, calories drop to a stricter 2-day basis while protein
    /// and carbs stay on 3 — so the identity genuinely stops holding,
    /// and a test that applied it unconditionally would be wrong rather
    /// than merely over-strict.
    func testTheIdentityDoesNotHoldWhenDaySetsDiffer() throws {
        var logs = realDays
        logs[2].fatGrams = nil
        let s = try XCTUnwrap(summary(logs: logs, days: 3))

        XCTAssertFalse(s.dayCountsAreUniform)
        XCTAssertEqual(s.calories.dayCount, 2, "day 2 has no fat, so it can't carry calories")
        let protein = try XCTUnwrap(s.variances.first { $0.category == .protein })
        XCTAssertEqual(protein.average.dayCount, 3, "protein still averages over all three")

        let p = try XCTUnwrap(protein.average.mean)
        let c = try XCTUnwrap(s.variances.first { $0.category == .carbs }.flatMap(\.average.mean))
        let f = try XCTUnwrap(s.variances.first { $0.category == .fat }.flatMap(\.average.mean))
        let mean = try XCTUnwrap(s.calories.mean)
        XCTAssertNotEqual(4 * p + 4 * c + 9 * f, mean, accuracy: 1.0,
                          "the bases differ, so these two figures describe different day sets — "
                          + "if they ever match here, CalorieAverage has stopped using the "
                          + "stricter basis and the gate below is no longer load-bearing")

        // What it IS: the mean of each complete day's own calories.
        let complete = logs.filter { $0.fatGrams != nil }
        let expected = complete.reduce(0.0) { $0 + ($1.calories ?? 0) } / Double(complete.count)
        XCTAssertEqual(mean, expected, accuracy: 1e-9)
    }
}
