//
//  RestBankEngineTests.swift
//  TheJymTests
//
//  Verifies StatsEngine.computeRestBank against hand-traced expectations
//  for the scenarios called out when the rest-bank model replaced the old
//  schedule-walking streak: a perfectly-followed split, a travel-week gap
//  that must survive, a stretch of missed days that must break, a no-phase
//  user's own weekly setting, a mid-history earn-rate change, and a long
//  dormant gap followed by a return that must start fresh.
//

import XCTest
@testable import TheJym

final class RestBankEngineTests: XCTestCase {
    private let cal = Calendar.current
    /// Fixed anchor so every test's dates are deterministic regardless of
    /// when the suite runs.
    private lazy var referenceDay = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    private func day(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n - 1, to: referenceDay)!
    }

    // MARK: - PPLR steady state

    /// Following a Push/Pull/Legs/Rest split exactly (train every P/P/L,
    /// nothing logged on Rest) for 5 full cycles never breaks — the earn
    /// rate (1 rest / 3 training ≈ 0.33) is tuned to exactly offset the
    /// single rest day each cycle, so the bank oscillates between ~0.67 and
    /// ~1.67 forever without dipping below 0.
    func testPPLRSteadyState() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        XCTAssertEqual(rate, 1.0 / 3.0, accuracy: 1e-9)

        var credited: [Date] = []
        var i = 1
        for _ in 0..<5 {
            credited.append(day(i)); i += 1   // Push
            credited.append(day(i)); i += 1   // Pull
            credited.append(day(i)); i += 1   // Legs
            i += 1                            // Rest — nothing logged
        }
        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        // `now` lands on the 5th Rest day, which is still pending (nothing
        // logged there yet today), so the walk stops after the 15th
        // credited day without processing it.
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(i - 1))

        XCTAssertEqual(result.currentStreak, 15)
        XCTAssertEqual(result.maxStreak, 15)
        XCTAssertEqual(result.bankBalance, 5.0 / 3.0, accuracy: 1e-6)
    }

    // MARK: - PPLRRPPL travel week

    /// Same PPLR rate, but the bank is topped up to its 2.0 cap first (4
    /// straight training days), then hit with an extra travel day off —
    /// two Rest days back to back instead of one. Two full rest days cost
    /// exactly the 2.0 cap, so the streak must survive (never resets to 0
    /// mid-gap) as long as the bank was fully topped up beforehand.
    func testTravelWeekSurvivesDoubleRestGap() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        var credited: [Date] = []
        var i = 1
        for _ in 0..<4 { credited.append(day(i)); i += 1 }   // P P P P -> caps bank at 2.0
        i += 2                                               // R R (the travel gap)
        credited.append(day(i)); i += 1                      // P
        credited.append(day(i)); i += 1                      // P
        credited.append(day(i)); i += 1                      // L

        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]

        // Check the streak right after the gap (day 7, the first P back)
        // never got reset to 0 by the two rest days that preceded it — if
        // it had broken, day 7's credit would restart the streak at 1
        // instead of continuing on to 5.
        let afterGap = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(7))
        XCTAssertEqual(afterGap.currentStreak, 5, "streak must survive the double rest-day gap")
        XCTAssertGreaterThanOrEqual(afterGap.bankBalance, 0)

        let final = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(i - 1))
        XCTAssertEqual(final.currentStreak, 7)
        XCTAssertEqual(final.maxStreak, 7)
    }

    // MARK: - Three consecutive zero days

    /// One credited day, then three days in a row with nothing logged — the
    /// second uncredited day already drops the bank below 0, breaking the
    /// streak and closing the ledger, so the bank sits at a clean 0 rather
    /// than continuing to accumulate debt through the third zero day.
    func testThreeZeroDaysBreaksStreak() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        let credited = [day(1)]
        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(5))

        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.maxStreak, 1)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - Logging a rest day spends the bank instead of growing it

    /// Day 1 trains (bank -> 1.0). Day 2 logs a plain rest day (the "Log
    /// Rest Day" button, ActiveRecovery) — spends 1.0 from the bank rather
    /// than earning at the rate, floored at 0, streak stays open. Day 3
    /// logs another rest day — bank is already 0, stays at 0 (floor, not
    /// negative), streak still doesn't break. Day 4 has nothing logged at
    /// all — that DOES spend into negative and breaks the streak, since an
    /// unlogged day (unlike an intentionally-logged rest day) isn't
    /// accounted for.
    func testLoggedRestDaySpendsBankButNeverBreaksStreak() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]

        let afterOneRest = StatsEngine.computeRestBank(
            trainingCreditedDates: [day(1)], restCreditedDates: [day(2)],
            ratePeriods: periods, now: day(2))
        XCTAssertEqual(afterOneRest.currentStreak, 2, "Logging a rest day keeps the streak alive")
        XCTAssertEqual(afterOneRest.bankBalance, 0, accuracy: 1e-9, "Spent the 1.0 earned on day 1")

        let afterTwoRests = StatsEngine.computeRestBank(
            trainingCreditedDates: [day(1)], restCreditedDates: [day(2), day(3)],
            ratePeriods: periods, now: day(3))
        XCTAssertEqual(afterTwoRests.currentStreak, 3, "Still alive — floored at 0, never went negative")
        XCTAssertEqual(afterTwoRests.bankBalance, 0, accuracy: 1e-9)

        // now: day(5), not day(4) — "today" is left pending (neither earned
        // nor spent) if nothing's logged for it yet, so day 4 needs to
        // already be in the past to be processed as an actual miss.
        let afterSilentDay = StatsEngine.computeRestBank(
            trainingCreditedDates: [day(1)], restCreditedDates: [day(2), day(3)],
            ratePeriods: periods, now: day(5))
        XCTAssertEqual(afterSilentDay.currentStreak, 0, "An unlogged day, unlike a logged rest day, breaks the streak")
        XCTAssertEqual(afterSilentDay.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - No-phase user, 4 days/week

    /// A non-Phase user's earn rate comes from the "Training days per
    /// week" setting instead of a split: 4 days/week -> 3 rest days -> rate
    /// 3/4 = 0.75. Training 4 days straight then resting covers a 2-day
    /// gap (bank hits the 2.0 cap, same as any other rate would).
    func testNoPhaseFourDaysPerWeek() {
        let rate = StatsEngine.earnRate(restDays: 3, trainingDays: 4)
        XCTAssertEqual(rate, 0.75, accuracy: 1e-9)

        var credited: [Date] = []
        var i = 1
        for _ in 0..<4 { credited.append(day(i)); i += 1 }
        i += 2   // two rest days

        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(i))

        XCTAssertEqual(result.currentStreak, 4)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - Earn-rate change mid-history

    /// Days 1-4 run under a stingy 0.15 rate (e.g. a 7-day/week setting) and
    /// break by day 3, closing that streak's ledger. Day 5 starts a brand
    /// new streak (fresh at 1.0, per the ledger-closed rule) right as the
    /// rate switches to a generous 1.0 (e.g. after lowering to a 3.5-day/
    /// week setting) — day 6's credited addition must reflect the NEW rate,
    /// not a retroactive recompute of the whole history under one rate.
    func testEarnRateChangeMidHistoryAppliesForward() {
        let boundary = day(5)
        let periods = [
            StatsEngine.RatePeriod(start: .distantPast, earnRate: 0.15),
            StatsEngine.RatePeriod(start: boundary, earnRate: 1.0),
        ]
        let credited = [day(1), day(5), day(6), day(8)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(8))

        // Day 6 adds the new 1.0 rate on top of day 5's fresh 1.0 start,
        // reaching the 2.0 cap — that only happens if the new rate (not the
        // old 0.15) is what's actually being applied from day 5 onward.
        XCTAssertEqual(result.bankBalance, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result.currentStreak, 3)
        XCTAssertEqual(result.maxStreak, 3)
    }

    // MARK: - 14-day gap then return

    /// A long dormant stretch (14 uncredited days) breaks the streak almost
    /// immediately and closes the ledger. When training resumes, the new
    /// streak must start clean — 1 day, bank at 1.0 — not inherit the debt
    /// that would have piled up over two weeks of misses.
    func testFourteenDayGapThenReturnStartsFresh() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        var credited: [Date] = [day(1), day(2)]
        credited.append(day(17))   // 14 uncredited days (3...16) in between

        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(17))

        XCTAssertEqual(result.currentStreak, 1, "the new streak must start at 1, not inherit the old one")
        XCTAssertEqual(result.bankBalance, 1.0, accuracy: 1e-9, "bank must reset to 1.0, not carry forward debt")
    }

    // MARK: - Max-streak date range

    /// A closed (already-broken) max streak: just day 1, breaking by day 3.
    /// Its range should report day1...day1, no preceding break (it's the
    /// very first credited day in history), and day3 as what broke it.
    func testMaxStreakRangeForAClosedStreak() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        let credited = [day(1)]
        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(5))

        guard let range = result.maxStreakRange else { return XCTFail("Expected a maxStreakRange") }
        XCTAssertEqual(cal.isDate(range.start, inSameDayAs: day(1)), true)
        XCTAssertEqual(cal.isDate(range.end, inSameDayAs: day(1)), true)
        XCTAssertNil(range.precedingBreakDate, "Nothing came before the very first credited day")
        XCTAssertNotNil(range.followingBreakDate)
        if let following = range.followingBreakDate {
            XCTAssertEqual(cal.isDate(following, inSameDayAs: day(3)), true)
        }
    }

    /// The earn-rate-change scenario has two streak instances: day1 alone
    /// (breaks by day3), then day5/6/8 (still open, currently the record at
    /// 3) — the range should point at the SECOND streak, with day3 as what
    /// closed the first one and no following break (still ongoing).
    func testMaxStreakRangeCarriesPrecedingBreakFromThePriorStreak() {
        let boundary = day(5)
        let periods = [
            StatsEngine.RatePeriod(start: .distantPast, earnRate: 0.15),
            StatsEngine.RatePeriod(start: boundary, earnRate: 1.0),
        ]
        let credited = [day(1), day(5), day(6), day(8)]
        let result = StatsEngine.computeRestBank(trainingCreditedDates: credited, restCreditedDates: [], ratePeriods: periods, now: day(8))

        guard let range = result.maxStreakRange else { return XCTFail("Expected a maxStreakRange") }
        XCTAssertEqual(cal.isDate(range.start, inSameDayAs: day(5)), true)
        XCTAssertEqual(cal.isDate(range.end, inSameDayAs: day(8)), true)
        XCTAssertNotNil(range.precedingBreakDate)
        if let preceding = range.precedingBreakDate {
            XCTAssertEqual(cal.isDate(preceding, inSameDayAs: day(3)), true)
        }
        XCTAssertNil(range.followingBreakDate, "Still the ongoing streak — hasn't broken yet")
    }
}
