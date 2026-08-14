//
//  RestBankEngineTests.swift
//  TheJymTests
//
//  Verifies StatsEngine.computeRestBank against the deposit-based rest-bank
//  model: training is bank-neutral, the bank only moves via credit events
//  (+2 phase start, +2 each cycle finish except the last) and rest-day
//  spends (activity -0.5, plain/unscheduled -1.0), and Phase.cycleCompletionDates/
//  restBankCreditEvents actually produce the right events from real history.
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

    // MARK: - Training is bank-neutral

    /// Training every day, nothing credited or spent — the bank simply
    /// never moves off 0, and the streak just keeps counting.
    func testTrainingAloneIsBankNeutral() {
        let credited = [day(1), day(2), day(3), day(4), day(5)]
        let result = StatsEngine.computeRestBank(trainingDates: credited, activityRestDates: [],
                                                  plainRestDates: [], creditEvents: [], now: day(5))
        XCTAssertEqual(result.currentStreak, 5)
        XCTAssertEqual(result.maxStreak, 5)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - Rest spends

    /// A plain/unscheduled rest day costs 1.0; with nothing credited yet,
    /// that immediately takes the bank negative and breaks on day 1 itself.
    func testPlainRestWithNoBankBreaksImmediately() {
        let result = StatsEngine.computeRestBank(trainingDates: [], activityRestDates: [],
                                                  plainRestDates: [day(1)], creditEvents: [], now: day(1))
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    /// A +2 credit (e.g. a phase starting) on day 1 covers a plain rest
    /// (-1.0) on day 2 with 1.0 to spare, and an activity rest (-0.5) on
    /// day 3 with 0.5 left after that — both survive.
    func testCreditCoversRestSpendsUntilExhausted() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [day(3)],
                                                  plainRestDates: [day(2)], creditEvents: credit, now: day(3))
        XCTAssertEqual(result.currentStreak, 3, "1.0 left after day 2, enough for day 3's 0.5 activity spend")
        XCTAssertEqual(result.bankBalance, 0.5, accuracy: 1e-9)
    }

    /// Same shape, but day 3 is a plain rest (-1.0) instead of an activity
    /// (-0.5) — only 1.0 was left after day 2's spend, so it lands exactly
    /// at 0 and still survives (0 isn't negative).
    func testCreditExactlyCoversTwoPlainRestSpends() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3)], creditEvents: credit, now: day(3))
        XCTAssertEqual(result.currentStreak, 3)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    /// One more plain rest than the credit can cover breaks the streak
    /// right on the day the spend would go negative, and closes the ledger
    /// (bank sits at a clean 0, not carrying the overdraft as debt).
    func testExhaustingTheBankBreaksTheStreakAndClosesTheLedger() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  creditEvents: credit, now: day(4))
        XCTAssertEqual(result.currentStreak, 0, "day 4's rest has nothing left to spend -- breaks")
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
        XCTAssertEqual(result.maxStreak, 3, "days 1-3 still stood before the break")
    }

    /// A blank/unlogged day, while a streak is open, spends 1.0 exactly
    /// like an explicitly-logged plain rest day would.
    func testUnloggedDayWithinAnOpenStreakSpendsLikePlainRest() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        // day(2) is deliberately absent from every date list -- nothing
        // logged there at all.
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(3)], activityRestDates: [],
                                                  plainRestDates: [], creditEvents: credit, now: day(3))
        XCTAssertEqual(result.currentStreak, 2, "day 2's silent gap cost 1.0 but didn't break it")
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9)
    }

    // MARK: - Fresh restart after a break

    /// After a break, the next credited day starts a brand-new streak at a
    /// clean 0 -- it does not inherit any debt, and a bare credit landing
    /// on the SAME closed-ledger day it broke on (or any day before the
    /// next credited one) is simply lost, not banked for later.
    func testFreshRestartAfterABreakDoesNotInheritDebt() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        // day 1 credited (+2), day 2/3/4 plain rest (-1 each) -- breaks on
        // day 3 (2.0 - 1.0 - 1.0 = 0, then day 4's -1.0 goes negative).
        // day 5 is training again, starting fresh.
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(5)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  creditEvents: credit, now: day(5))
        XCTAssertEqual(result.currentStreak, 1, "day 5 starts a brand-new streak")
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9, "training alone is neutral -- no debt carried in")
    }

    /// A bare credit event landing on a day with nothing else logged, while
    /// the ledger is closed (no streak open), doesn't spontaneously open
    /// one -- the credit is simply lost.
    func testBareCreditCannotOpenAStreakOnItsOwn() {
        // Nothing at all logged on day 1 even though a credit lands there --
        // firstDay is derived only from actual training/rest dates, so with
        // none at all, there's nothing to walk.
        let result = StatsEngine.computeRestBank(trainingDates: [], activityRestDates: [],
                                                  plainRestDates: [], creditEvents: [(day(1), 2.0)], now: day(3))
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.maxStreak, 0)
    }

    // MARK: - Today pending

    /// Nothing logged yet today -- the walk stops without processing it,
    /// same as before.
    func testTodayIsPendingUntilSomethingIsLogged() {
        let result = StatsEngine.computeRestBank(trainingDates: [day(1), day(2)], activityRestDates: [],
                                                  plainRestDates: [], creditEvents: [], now: day(3))
        XCTAssertEqual(result.currentStreak, 2, "day 3 (today) isn't counted yet")
    }

    // MARK: - Max-streak date range

    /// A closed (already-broken) max streak: day 1 alone (a +2 credit, no
    /// spend), then two plain rests exhaust it and a third breaks it on
    /// day 4. Range should report day1...day1 (the streak's actual span,
    /// not the rest days that came after it broke -- those aren't part of
    /// ITS streak), no preceding break, and day 4 as what broke it.
    func testMaxStreakRangeForAClosedStreak() {
        let credit: [(date: Date, amount: Double)] = [(day(1), 2.0)]
        let result = StatsEngine.computeRestBank(trainingDates: [day(1)], activityRestDates: [],
                                                  plainRestDates: [day(2), day(3), day(4)],
                                                  creditEvents: credit, now: day(4))

        guard let range = result.maxStreakRange else { return XCTFail("Expected a maxStreakRange") }
        XCTAssertEqual(cal.isDate(range.start, inSameDayAs: day(1)), true)
        XCTAssertEqual(cal.isDate(range.end, inSameDayAs: day(3)), true)
        XCTAssertNil(range.precedingBreakDate, "Nothing came before the very first credited day")
        XCTAssertNotNil(range.followingBreakDate)
        if let following = range.followingBreakDate {
            XCTAssertEqual(cal.isDate(following, inSameDayAs: day(4)), true)
        }
    }

    // MARK: - Phase.cycleCompletionDates / restBankCreditEvents (integration)

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Trains every slot of a 2-cycle, 2-day (Upper/Lower) phase back to
    /// back -- cycle 1 completes on its 2nd day logged, cycle 2 (the LAST
    /// cycle) also completes, but only cycle 1's completion should produce
    /// a credit event since it's not the phase's last cycle.
    @MainActor
    func testRestBankCreditEventsSkipTheLastCycle() {
        let context = makeContext()
        let phase = Phase(number: 1, totalCycles: 2, startDate: day(1))
        context.insert(phase)
        let upper = PhaseDay(order: 0, name: "Upper", isRest: false); upper.phase = phase; context.insert(upper)
        let lower = PhaseDay(order: 1, name: "Lower", isRest: false); lower.phase = phase; context.insert(lower)

        func log(_ phaseDay: PhaseDay, on date: Date, cycle: Int) {
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

        log(upper, on: day(1), cycle: 1)
        log(lower, on: day(2), cycle: 1)   // cycle 1 completes on day 2
        log(upper, on: day(3), cycle: 2)
        log(lower, on: day(4), cycle: 2)   // cycle 2 (last) completes on day 4

        XCTAssertEqual(phase.cycleCompletionDates.count, 2, "both cycles verified complete")
        XCTAssertEqual(cal.isDate(phase.cycleCompletionDates[1]!, inSameDayAs: day(2)), true)
        XCTAssertEqual(cal.isDate(phase.cycleCompletionDates[2]!, inSameDayAs: day(4)), true)

        let events = phase.restBankCreditEvents
        // startDate (day 1) + cycle 1's finish (day 2) -- NOT cycle 2's,
        // since totalCycles is 2 and cycle 2 is the last one.
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { cal.isDate($0.date, inSameDayAs: day(1)) && $0.amount == 2.0 })
        XCTAssertTrue(events.contains { cal.isDate($0.date, inSameDayAs: day(2)) && $0.amount == 2.0 })
        XCTAssertFalse(events.contains { cal.isDate($0.date, inSameDayAs: day(4)) },
                       "the last cycle's own finish shouldn't grant a credit")
    }
}
