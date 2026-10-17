//
//  RestBankEngineTests.swift
//  TheJymTests
//
//  Verifies StatsEngine.computeRestBank against the reset-based rest-bank
//  model: the bank RESETS (not adds) to restDaysPerCycle when a phase's
//  first session is logged and again each time a cycle finishes (except the
//  last); training, activity-logged rest and plain LOGGED rest all grow the
//  streak count (rest of either kind still spends the bank and can still
//  break the streak); an UNLOGGED day spends without counting; and
//  Phase.cycleCompletionDates/firstLoggedDate/restBankResetEvents actually
//  produce the right events from real logged history.
//

import XCTest
import SwiftData
@testable import TheJym

final class RestBankEngineTests: XCTestCase {
    private let cal = Calendar.current
    /// Fixed anchor so every test's dates are deterministic regardless of
    /// when the suite runs.
    private lazy var referenceDay = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    private func day(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n - 1, to: referenceDay)!
    }

    // MARK: - Training is bank-neutral, and grows the streak

    /// Training every day, nothing reset or spent — the bank simply never
    /// moves off 0, and the streak counts every one of them.
    func testTrainingAloneIsBankNeutralAndGrowsTheStreak() {
        let credited = [day(1), day(2), day(3), day(4), day(5)]
        let result = StatsEngine.computeRestBank(trainingDates: credited, activityRestDates: [],
                                                  plainRestDates: [], resetEvents: [], now: day(5))
        XCTAssertEqual(result.currentStreak, 5)
        XCTAssertEqual(result.maxStreak, 5)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    /// An activity-logged rest day ALSO grows the streak count (same as
    /// training), even though it spends 0.5 from the bank.
    func testActivityRestGrowsTheStreak() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [day(2), day(3)],
                                                  plainRestDates: [], resetEvents: reset, now: day(3))
        XCTAssertEqual(result.currentStreak, 3, "training + 2 activity-rest days, all countable")
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9, "2.0 - 0.5 - 0.5")
    }

    // MARK: - A plain LOGGED rest day spends AND counts

    /// A plain LOGGED rest mid-streak, with the bank holding: it spends
    /// 1.0 and it counts. A rest day you told the app about is a day of
    /// the program, and the bank is what stops that inflating anything —
    /// you can only spend what a cycle earned.
    ///
    /// Sabotage: drop the `recordCredit(on: day, isRest: true)` in
    /// computeRestBank's no-reset branch and this reads 2, not 3.
    func testPlainRestGrowsTheStreakAndStillSpends() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(3)], activityRestDates: [],
                                                  plainRestDates: [day(2)], resetEvents: reset, now: day(3))
        XCTAssertEqual(result.currentStreak, 3, "two training days plus day 2's logged rest")
        XCTAssertEqual(result.currentStreakRestDays, 1, "exactly one of those three was a rest day")
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9, "2.0 - 1.0 (day 2's spend), day 3 training is neutral")
    }

    /// With nothing banked yet, a plain rest day immediately goes negative
    /// and breaks right there.
    func testPlainRestWithNoBankBreaksImmediately() {
        let result = StatsEngine.computeRestBank(trainingDates: [], activityRestDates: [],
                                                  plainRestDates: [day(1)], resetEvents: [], now: day(1))
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - Reset, not additive

    /// A second reset event completely overwrites whatever was left in the
    /// bank rather than adding to it -- spend it most of the way down, then
    /// a fresh reset brings it back up to exactly the reset value, not the
    /// reset value plus whatever remained.
    func testResetEventOverwritesRatherThanAdding() {
        let resets: [(date: Date, resetTo: Double)] = [(day(1), 2.0), (day(3), 1.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(3)], activityRestDates: [],
                                                  plainRestDates: [day(2)], resetEvents: resets, now: day(3))
        // day1: reset to 2.0 (training, neutral) -> 2.0
        // day2: plain rest -> 2.0 - 1.0 = 1.0
        // day3: RESET to 1.0 (not 1.0 + 1.0 = 2.0), training is neutral -> stays 1.0
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9)
    }

    // MARK: - Reset on a cycle's last day: spend is judged against the OLD
    // bank, then the reset unconditionally overwrites the result -- even
    // reopening the streak same-day if that spend just broke it.

    /// At 0.5, a plain rest as the cycle's last day: the spend (-1.0) goes
    /// negative against the OLD bank, breaking the streak -- but because
    /// this day also completes the cycle, the bank still ends reset to
    /// 2.0, not 0.
    ///
    /// THE ORDER IS THE POINT. A logged rest normally counts, but the
    /// break happens first, and the reset reopening the ledger on this
    /// same date must not hand it the credit for the day it broke on. The
    /// reopened streak starts empty, at 0 -- not 1.
    ///
    /// Sabotage: drop the `!brokeToday` guard on the plain-rest branch
    /// inside computeRestBank's reset arm and this reads 1.
    func testLastDayPlainRestBreaksBeforeTheResetAndIsNotCreditedForIt() {
        // day1: training, reset 1.5 -> bank 1.5. day2: plain rest (no reset)
        // -> bank 0.5, streak still just day1's 1. day3: the cycle's last
        // day, itself a plain rest, WITH its own reset to 2.0.
        let resets: [(date: Date, resetTo: Double)] = [(day(1), 1.5), (day(3), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3)],
                                                  resetEvents: resets, now: day(3))
        XCTAssertEqual(result.currentStreak, 0,
                       "day 3's plain rest broke it against the pre-reset 0.5, and the reset "
                       + "reopening the ledger on the same date doesn't credit the breaking day")
        XCTAssertEqual(result.currentStreakRestDays, 0, "nothing counted into the reopened streak")
        XCTAssertEqual(result.bankBalance, 2.0, accuracy: 1e-9, "still resets despite the break")
    }

    /// The same shape with the bank able to afford it: a plain rest on a
    /// cycle-completion day that stays non-negative IS credited, and the
    /// reset still lands on top.
    ///
    /// This is the counterpart to the test above, and the pair is what
    /// shows the `!brokeToday` guard is a guard rather than a blanket
    /// refusal to credit rest on reset days.
    func testCycleCompletionPlainRestTheBankCanAffordIsCredited() {
        // day1: training, reset 2.0 -> bank 2.0. day2: training, neutral.
        // day3: the cycle's last day, a plain rest, WITH its own reset.
        let resets: [(date: Date, resetTo: Double)] = [(day(1), 2.0), (day(3), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(2)], activityRestDates: [],
                                                  plainRestDates: [day(3)],
                                                  resetEvents: resets, now: day(3))
        XCTAssertEqual(result.currentStreak, 3, "two training days plus the affordable logged rest")
        XCTAssertEqual(result.currentStreakRestDays, 1, "day 3")
        XCTAssertEqual(result.bankBalance, 2.0, accuracy: 1e-9, "the cycle reset lands on top of the spend")
    }

    /// At 0.5, a rest ACTIVITY as the cycle's last day: the spend (-0.5)
    /// lands exactly at 0 against the OLD bank -- non-negative, so the
    /// streak does NOT break, and actually grows by 1 (activity days always
    /// count). The bank still ends reset to 2.0 on top of that.
    func testLastDayActivityRestSurvivesAndGrowsStreakThenBankResets() {
        // day1: training, reset 1.5 -> bank 1.5. day2: plain rest (no
        // reset) -> bank 0.5, streak still 1. day3: the cycle's last day,
        // an activity rest, WITH its own reset to 2.0.
        let resets: [(date: Date, resetTo: Double)] = [(day(1), 1.5), (day(3), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [day(3)],
                                                  plainRestDates: [day(2)],
                                                  resetEvents: resets, now: day(3))
        XCTAssertEqual(result.currentStreak, 3,
                       "never broke -- day 1's training, day 2's logged rest, day 3's activity")
        XCTAssertEqual(result.currentStreakRestDays, 1, "day 2")
        XCTAssertEqual(result.bankBalance, 2.0, accuracy: 1e-9)
    }

    /// At 0, a rest ACTIVITY as the cycle's last day: the spend (-0.5)
    /// would take it negative against the OLD bank (clamped at 0, can't go
    /// below), breaking the streak -- but since it's an activity day, it
    /// STILL earns 1 toward the freshly-restarted streak (not 0), and the
    /// bank still ends reset to 2.0.
    func testLastDayActivityRestBreaksButStillEarnsOneThenBankResets() {
        // day1: training, reset 1.0 -> bank 1.0. day2: plain rest (no
        // reset) -> bank 0.0, streak still 1. day3: the cycle's last day,
        // an activity rest, WITH its own reset to 2.0.
        let resets: [(date: Date, resetTo: Double)] = [(day(1), 1.0), (day(3), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [day(3)],
                                                  plainRestDates: [day(2)],
                                                  resetEvents: resets, now: day(3))
        XCTAssertEqual(result.currentStreak, 1, "broke against the pre-reset 0, but day 3's own activity still earns 1")
        XCTAssertEqual(result.bankBalance, 2.0, accuracy: 1e-9)
    }

    // MARK: - Exhausting the bank breaks the streak

    /// One more plain rest than the bank can cover breaks the streak right
    /// on the day the spend would go negative, and closes the ledger (bank
    /// sits at a clean 0, not carrying the overdraft as debt). The streak
    /// count at the break reflects only the training days that came before
    /// it -- the plain rests along the way never added to it anyway.
    func testExhaustingTheBankBreaksTheStreakAndClosesTheLedger() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  resetEvents: reset, now: day(4))
        XCTAssertEqual(result.currentStreak, 0, "day 4's rest has nothing left to spend -- breaks")
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
        XCTAssertEqual(result.maxStreak, 3, "day 1's training plus days 2 and 3's logged rests, "
                       + "which the bank could still afford")
        XCTAssertEqual(result.maxStreakRestDays, 2, "two of that record's three days were rests")
        XCTAssertEqual(result.currentStreakRestDays, 0, "the broken streak carries nothing forward")
    }

    /// A blank/unlogged day, while the ledger is open, spends 1.0 exactly
    /// like an explicitly-logged plain rest day would (and likewise doesn't
    /// grow the streak).
    func testUnloggedDayWithinAnOpenLedgerSpendsLikePlainRest() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        // day(2) is deliberately absent from every date list -- nothing
        // logged there at all.
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(3)], activityRestDates: [],
                                                  plainRestDates: [], resetEvents: reset, now: day(3))
        XCTAssertEqual(result.currentStreak, 2, "day 2's silent gap cost 1.0 but didn't break it, and didn't count")
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9)
    }

    // MARK: - Fresh restart after a break

    /// After a break, the next credited day starts a brand-new streak at a
    /// clean 0 -- it does not inherit any debt.
    @MainActor
    func testFreshRestartAfterABreakDoesNotInheritDebt() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        // day 1 trains (reset to 2.0), day 2/3/4 plain rest (-1 each) --
        // breaks on day 4 (2.0 - 1.0 - 1.0 = 0, then day 4's -1.0 goes
        // negative). day 5 is training again, starting fresh.
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(5)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  resetEvents: reset, now: day(5))
        XCTAssertEqual(result.currentStreak, 1, "day 5 starts a brand-new streak")
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9, "training alone is neutral -- no debt carried in")
    }

    /// A bare reset event landing on a day with nothing else logged, while
    /// the ledger is closed (no streak open), doesn't spontaneously open
    /// one -- the reset is simply lost.
    func testBareResetCannotOpenAStreakOnItsOwn() {
        let result = StatsEngine.computeRestBank(trainingDates: [], activityRestDates: [],
                                                  plainRestDates: [], resetEvents: [(day(1), 2.0)], now: day(3))
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.maxStreak, 0)
    }

    // MARK: - Today pending

    func testTodayIsPendingUntilSomethingIsLogged() {
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(2)], activityRestDates: [],
                                                  plainRestDates: [], resetEvents: [], now: day(3))
        XCTAssertEqual(result.currentStreak, 2, "day 3 (today) isn't counted yet")
    }

    // MARK: - Max-streak date range

    /// A closed (already-broken) max streak: day 1 trains (reset to 2.0),
    /// two plain rests exhaust it (neither counts toward the streak), and a
    /// third breaks it on day 4. Range should report day1...day1 (the only
    /// day that actually counted), no preceding break, and day 4 as what
    /// broke it.
    func testMaxStreakRangeForAClosedStreak() {
        let reset: [(date: Date, resetTo: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  resetEvents: reset, now: day(4))

        guard let range = result.maxStreakRange else { return XCTFail("Expected a maxStreakRange") }
        XCTAssertEqual(cal.isDate(range.start, inSameDayAs: day(1)), true)
        XCTAssertEqual(cal.isDate(range.end, inSameDayAs: day(3)), true,
                       "the record now runs to day 3 -- days 2 and 3 are logged rests the bank "
                       + "could afford, and they count")
        XCTAssertNil(range.precedingBreakDate, "Nothing came before the very first credited day")
        XCTAssertNotNil(range.followingBreakDate)
        if let following = range.followingBreakDate {
            XCTAssertEqual(cal.isDate(following, inSameDayAs: day(4)), true)
        }
    }

    // MARK: - Phase.cycleCompletionDates / firstLoggedDate / restBankResetEvents (integration)

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func log(_ phaseDay: PhaseDay, on date: Date, cycle: Int, phase: Phase, context: ModelContext) {
        let session = WorkoutSession(date: date, day: phaseDay, dayLabel: phaseDay.name, cycleNumber: cycle)
        session.phase = phase
        context.insert(session)
        let log = ExerciseLog(exerciseName: "Bench", targetReps: [5], order: 0)
        log.session = session
        context.insert(log)
        let set = SetLog(index: 0, weight: 100, reps: 5)
        set.exerciseLog = log
        context.insert(set)
    }

    /// Trains every slot of a 2-cycle, 3-day (Upper/Lower/Rest) phase back
    /// to back, with the phase CREATED (startDate) a week before it's
    /// actually first trained -- cycle 1 completes on its 3rd day logged,
    /// cycle 2 (the LAST cycle) also completes, but only cycle 1's
    /// completion should produce a reset event, and the initial reset
    /// should land on the first LOGGED day, not startDate.
    @MainActor
    func testRestBankResetEventsUseFirstLoggedDateAndSkipTheLastCycle() {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 2, startDate: day(1))   // created day 1
        context.insert(phase)
        let upper = PhaseDay(order: 0, name: "Upper", isRest: false); upper.phase = phase; context.insert(upper)
        let lower = PhaseDay(order: 1, name: "Lower", isRest: false); lower.phase = phase; context.insert(lower)
        let rest = PhaseDay(order: 2, name: "Rest", isRest: true); rest.phase = phase; context.insert(rest)

        // Actually first trained on day 8, a week after startDate.
        log(upper, on: day(8), cycle: 1, phase: phase, context: context)
        log(lower, on: day(9), cycle: 1, phase: phase, context: context)
        log(rest, on: day(10), cycle: 1, phase: phase, context: context)     // cycle 1 completes day 10
        log(upper, on: day(11), cycle: 2, phase: phase, context: context)
        log(lower, on: day(12), cycle: 2, phase: phase, context: context)
        log(rest, on: day(13), cycle: 2, phase: phase, context: context)     // cycle 2 (last) completes day 13

        XCTAssertEqual(phase.firstLoggedDate.map { cal.startOfDay(for: $0) }, day(8))
        XCTAssertEqual(phase.restDaysPerCycle, 1.0, "one Rest slot in the 3-day template")
        XCTAssertEqual(phase.cycleCompletionDates.count, 2)
        XCTAssertEqual(cal.isDate(phase.cycleCompletionDates[1]!, inSameDayAs: day(10)), true)
        XCTAssertEqual(cal.isDate(phase.cycleCompletionDates[2]!, inSameDayAs: day(13)), true)

        let events = phase.restBankResetEvents
        // first logged day (day 8, NOT startDate day 1) + cycle 1's finish
        // (day 10) -- NOT cycle 2's, since it's the last cycle.
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { cal.isDate($0.date, inSameDayAs: day(8)) && $0.resetTo == 1.0 })
        XCTAssertTrue(events.contains { cal.isDate($0.date, inSameDayAs: day(10)) && $0.resetTo == 1.0 })
        XCTAssertFalse(events.contains { cal.isDate($0.date, inSameDayAs: day(1)) },
                       "startDate itself shouldn't grant a reset -- nothing was logged that day")
        XCTAssertFalse(events.contains { cal.isDate($0.date, inSameDayAs: day(13)) },
                       "the last cycle's own finish shouldn't grant a reset")
    }
}
