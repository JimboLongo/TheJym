//
//  MacroVarianceTests.swift
//  TheJymTests
//
//  Cycle averages and variance.
//
//  Two things carry the weight here. The CALORIE BASIS: averaging calories
//  from the per-category means would assemble one number out of three
//  different day sets, producing a figure that is no day's calories — and
//  it hides better than the per-category version because calories look
//  like a single measurement. And DIRECTION-AWARE STATUS: "+15g" on
//  protein is the target beaten, "+15g" on sugar is the ceiling breached.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class MacroVarianceTests: XCTestCase {
    private let cal = Calendar.current
    private func d(_ day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day))!
    }

    private func makeContext() -> ModelContext {
        let c = try! ModelContainer(
            for: AppSettings.self, Bar.self, ExerciseDef.self, Phase.self, PhaseDay.self,
            PlannedExercise.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            BodyWeightEntry.self, RestDayActivity.self, ActiveRecovery.self,
            TrainingDaysPerWeekChange.self, TimerTemplate.self, TimerPreset.self,
            BackupStatus.self, MacroTier.self, CycleMacroTag.self, MacroLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    private func tier() -> MacroTier {
        MacroTier(name: "2450", proteinGrams: 185, carbsGrams: 260,
                  fatGrams: 75, sugarGrams: 90, fiberGrams: 36)
    }

    // MARK: - The calorie basis

    /// A day missing fat must NOT contribute to the calorie average, even
    /// though its protein and carbs count toward theirs.
    func testCaloriesAverageOnlyOverFullyLoggedDays() {
        let logs = [
            MacroLog(date: d(1), proteinGrams: 185, carbsGrams: 260, fatGrams: 75),
            MacroLog(date: d(2), proteinGrams: 185, carbsGrams: 260),   // no fat
        ]
        let c = CalorieAverage.compute(over: logs)
        XCTAssertEqual(c.dayCount, 1, "only the complete day counts")
        XCTAssertEqual(c.mean ?? 0, 740 + 1040 + 675, accuracy: 1e-9)
    }

    /// The failure this basis exists to prevent, stated directly: averaging
    /// the category means would produce a number no day actually had.
    func testCalorieAverageIsNotAssembledFromCategoryMeans() {
        let logs = [
            MacroLog(date: d(1), proteinGrams: 200, carbsGrams: 200, fatGrams: 100),
            MacroLog(date: d(2), proteinGrams: 100),   // protein only
        ]
        // Category means: protein 150 (2d), carbs 200 (1d), fat 100 (1d).
        // Assembling those gives 4*150 + 4*200 + 9*100 = 2300.
        let assembled: Double = 600 + 800 + 900
        let c = CalorieAverage.compute(over: logs)
        XCTAssertEqual(c.dayCount, 1)
        XCTAssertEqual(c.mean ?? 0, 800 + 800 + 900, accuracy: 1e-9)
        XCTAssertNotEqual(c.mean ?? 0, assembled, accuracy: 1e-9,
                          "a figure built from three different day sets is no day's calories")
    }

    /// Sugar and fiber don't enter the calorie sum, so a day missing them
    /// is still a complete day for this purpose.
    func testSugarAndFiberDoNotGateTheCalorieCount() {
        let logs = [MacroLog(date: d(1), proteinGrams: 185, carbsGrams: 260, fatGrams: 75)]
        XCTAssertEqual(CalorieAverage.compute(over: logs).dayCount, 1)
    }

    func testCalorieAverageIsNilWithNoCompleteDay() {
        let c = CalorieAverage.compute(over: [MacroLog(date: d(1), proteinGrams: 185)])
        XCTAssertNil(c.mean)
        XCTAssertEqual(c.dayCount, 0)
    }

    // MARK: - Direction-aware status

    func testBeatingAnAtLeastTargetIsMet() {
        let v = MacroVariance(category: .protein,
                              average: MacroAverage(category: .protein, mean: 200, dayCount: 6),
                              target: 185)
        XCTAssertEqual(v.status, .met)
        XCTAssertEqual(v.delta ?? 0, 15, accuracy: 1e-9)
        XCTAssertTrue(v.status!.isFavourable, "+15 on protein is the target beaten")
    }

    func testExceedingAnAtMostTargetIsOver() {
        let v = MacroVariance(category: .sugar,
                              average: MacroAverage(category: .sugar, mean: 105, dayCount: 5),
                              target: 90)
        XCTAssertEqual(v.status, .over)
        XCTAssertEqual(v.delta ?? 0, 15, accuracy: 1e-9)
        XCTAssertFalse(v.status!.isFavourable, "+15 on sugar is the ceiling breached")
    }

    /// The same +15 reads oppositely on the two — the distinction that
    /// makes the readout worth having.
    func testIdenticalDeltasRenderOppositelyByDirection() {
        let protein = MacroVariance(category: .protein,
                                    average: MacroAverage(category: .protein, mean: 200, dayCount: 1),
                                    target: 185)
        let sugar = MacroVariance(category: .sugar,
                                  average: MacroAverage(category: .sugar, mean: 105, dayCount: 1),
                                  target: 90)
        XCTAssertEqual(protein.delta, sugar.delta)
        XCTAssertNotEqual(protein.status!.isFavourable, sugar.status!.isFavourable)
    }

    func testMissingAnAtLeastTargetIsUnder() {
        let v = MacroVariance(category: .fiber,
                              average: MacroAverage(category: .fiber, mean: 31, dayCount: 4),
                              target: 36)
        XCTAssertEqual(v.status, .under)
        XCTAssertFalse(v.status!.isFavourable)
    }

    // MARK: - The ±5% band, on ≈ only

    func testAboutTargetWithinFivePercentIsMet() {
        // Fat 75 -> band is 3.75, so 71.25...78.75.
        for mean in [75.0, 77.0, 78.7, 71.3] {
            let v = MacroVariance(category: .fat,
                                  average: MacroAverage(category: .fat, mean: mean, dayCount: 4),
                                  target: 75)
            XCTAssertEqual(v.status, .met, "fat \(mean) should be met")
        }
    }

    func testAboutTargetOutsideFivePercentMisses() {
        let over = MacroVariance(category: .fat,
                                 average: MacroAverage(category: .fat, mean: 80, dayCount: 4),
                                 target: 75)
        let under = MacroVariance(category: .fat,
                                  average: MacroAverage(category: .fat, mean: 70, dayCount: 4),
                                  target: 75)
        XCTAssertEqual(over.status, .over)
        XCTAssertEqual(under.status, .under)
    }

    /// Proportional, not flat: 5g off fat (6.7%) misses where 5g off carbs
    /// (1.9%) is met. A gram tolerance couldn't say that.
    func testTheBandIsProportionalNotFlat() {
        let fat = MacroVariance(category: .fat,
                                average: MacroAverage(category: .fat, mean: 80, dayCount: 1),
                                target: 75)
        let carbs = MacroVariance(category: .carbs,
                                  average: MacroAverage(category: .carbs, mean: 265, dayCount: 1),
                                  target: 260)
        XCTAssertEqual(fat.delta, carbs.delta, "the same 5g")
        XCTAssertEqual(fat.status, .over)
        XCTAssertEqual(carbs.status, .met)
    }

    /// One-sided targets get no band — softening them would move the line
    /// somewhere undocumented.
    func testOneSidedTargetsHaveNoTolerance() {
        let protein = MacroVariance(category: .protein,
                                    average: MacroAverage(category: .protein, mean: 184, dayCount: 1),
                                    target: 185)
        XCTAssertEqual(protein.status, .under, "1g short of \"at least\" is short")
        let sugar = MacroVariance(category: .sugar,
                                  average: MacroAverage(category: .sugar, mean: 91, dayCount: 1),
                                  target: 90)
        XCTAssertEqual(sugar.status, .over)
    }

    func testStatusIsNilWithNoData() {
        let v = MacroVariance(category: .protein,
                              average: MacroAverage(category: .protein, mean: nil, dayCount: 0),
                              target: 185)
        XCTAssertNil(v.status)
        XCTAssertNil(v.delta)
    }

    // MARK: - Cycle date ranges

    private func phaseWithCycles(_ ctx: ModelContext) -> Phase {
        let phase = Phase(number: 3, totalCycles: 8, startDate: d(1), isActive: true)
        ctx.insert(phase)
        let day = PhaseDay(order: 0, name: "Lower A", isRest: false)
        day.phase = phase
        ctx.insert(day)
        // Cycle 1 on the 1st, cycle 2 on the 8th — the 2nd-7th are cycle 1's.
        for (cycle, date) in [(1, d(1)), (2, d(8))] {
            let s = WorkoutSession(date: date, day: day, dayLabel: day.name, cycleNumber: cycle)
            s.phase = phase
            ctx.insert(s)
        }
        try? ctx.save()
        return phase
    }

    /// A cycle runs to the day BEFORE the next begins, so gap days belong
    /// to the cycle they followed rather than to nothing.
    func testCycleRangeRunsToTheDayBeforeTheNextCycle() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        let range = try! XCTUnwrap(phase.dateRange(forCycle: 1, now: d(20)))
        XCTAssertEqual(range.lowerBound, d(1))
        XCTAssertEqual(range.upperBound, d(7), "the 7th, not the 1st — gap days included")
        XCTAssertTrue(range.contains(d(5)))
    }

    /// The last cycle with sessions owns today.
    func testLastCycleRunsToNow() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        let range = try! XCTUnwrap(phase.dateRange(forCycle: 2, now: d(20)))
        XCTAssertEqual(range.lowerBound, d(8))
        XCTAssertEqual(range.upperBound, d(20))
    }

    func testCycleWithNoSessionsHasNoRange() {
        let ctx = makeContext()
        XCTAssertNil(phaseWithCycles(ctx).dateRange(forCycle: 5, now: d(20)))
    }

    // MARK: - End to end

    func testSummaryMapsLogsOntoTheRightCycle() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        let t = tier()
        ctx.insert(t)
        CycleMacroTag.set(t, for: phase, cycle: 1, context: ctx)
        // Day 3 is inside cycle 1's range; day 9 is inside cycle 2's.
        ctx.insert(MacroLog(date: d(3), proteinGrams: 200, carbsGrams: 260, fatGrams: 75))
        ctx.insert(MacroLog(date: d(9), proteinGrams: 100, carbsGrams: 100, fatGrams: 100))
        try? ctx.save()

        let logs = try! ctx.fetch(FetchDescriptor<MacroLog>())
        let summary = try! XCTUnwrap(MacroCycleSummary.compute(phase: phase, cycle: 1,
                                                               logs: logs, now: d(20)))
        XCTAssertEqual(summary.loggedDayCount, 1, "only day 3 is in cycle 1")
        let protein = summary.variances.first { $0.category == .protein }!
        XCTAssertEqual(protein.average.mean ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(protein.status, .met)
    }

    /// An untagged cycle has nothing to be measured against.
    func testUntaggedCycleHasNoSummary() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        XCTAssertNil(MacroCycleSummary.compute(phase: phase, cycle: 1, logs: [], now: d(20)))
    }

    func testTaggedCycleWithNoLogsReportsEmptyRatherThanZeroes() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        let t = tier()
        ctx.insert(t)
        CycleMacroTag.set(t, for: phase, cycle: 1, context: ctx)
        try? ctx.save()
        let summary = try! XCTUnwrap(MacroCycleSummary.compute(phase: phase, cycle: 1,
                                                               logs: [], now: d(20)))
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.calories.mean)
        XCTAssertTrue(summary.variances.allSatisfy { $0.average.mean == nil })
    }

    /// The counts genuinely differ across a partially-logged cycle, and the
    /// calorie count is stricter than any of them.
    func testCountsDifferAcrossAPartiallyLoggedCycle() {
        let ctx = makeContext()
        let phase = phaseWithCycles(ctx)
        let t = tier()
        ctx.insert(t)
        CycleMacroTag.set(t, for: phase, cycle: 1, context: ctx)
        ctx.insert(MacroLog(date: d(2), proteinGrams: 185, carbsGrams: 260,
                            fatGrams: 75, fiberGrams: 36))
        ctx.insert(MacroLog(date: d(3), proteinGrams: 190, carbsGrams: 250))  // no fat, no fiber
        ctx.insert(MacroLog(date: d(4), proteinGrams: 180))                   // protein only
        try? ctx.save()

        let logs = try! ctx.fetch(FetchDescriptor<MacroLog>())
        let s = try! XCTUnwrap(MacroCycleSummary.compute(phase: phase, cycle: 1,
                                                         logs: logs, now: d(20)))
        func count(_ c: MacroCategory) -> Int {
            s.variances.first { $0.category == c }!.average.dayCount
        }
        XCTAssertEqual(count(.protein), 3)
        XCTAssertEqual(count(.carbs), 2)
        XCTAssertEqual(count(.fat), 1)
        XCTAssertEqual(count(.fiber), 1)
        XCTAssertEqual(s.calories.dayCount, 1, "only one day has all of protein, carbs and fat")
        XCTAssertEqual(s.loggedDayCount, 3)
    }
}
