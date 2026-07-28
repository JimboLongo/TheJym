//
//  RestBankEngineTests.swift
//  TheJymTests
//
//  Verifies StatsEngine.computeRestBank against hand-traced expectations
//  for the scenarios called out when the rest-bank model replaced the old
//  schedule-walking streak: a perfectly-followed split, a travel-week gap
//  that must survive, a stretch of missed days that must break, a no-phase
//  user's own weekly setting, and a mid-history earn-rate change.
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
        let result = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(i - 1))

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
        let afterGap = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(7))
        XCTAssertEqual(afterGap.currentStreak, 5, "streak must survive the double rest-day gap")
        XCTAssertGreaterThanOrEqual(afterGap.bankBalance, 0)

        let final = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(i - 1))
        XCTAssertEqual(final.currentStreak, 7)
        XCTAssertEqual(final.maxStreak, 7)
    }

    // MARK: - Three consecutive zero days

    /// One credited day, then three days in a row with nothing logged —
    /// the second uncredited day already drops the bank below 0, breaking
    /// the streak back to 0.
    func testThreeZeroDaysBreaksStreak() {
        let rate = StatsEngine.earnRate(restDays: 1, trainingDays: 3)
        let credited = [day(1)]
        let periods = [StatsEngine.RatePeriod(start: .distantPast, earnRate: rate)]
        let result = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(5))

        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.maxStreak, 1)
        XCTAssertLessThan(result.bankBalance, 0)
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
        let result = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(i))

        XCTAssertEqual(result.currentStreak, 4)
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
    }

    // MARK: - Earn-rate change mid-history

    /// Days 1-4 run under a stingy 0.15 rate (e.g. a 7-day/week setting)
    /// and break by day 3. Day 5 onward switches to a generous 1.0 rate
    /// (e.g. after lowering to a 3.5-day/week setting) — day 5's credited
    /// addition must reflect the NEW rate applied from its effective date,
    /// not a retroactive recompute of the whole history under one rate.
    func testEarnRateChangeMidHistoryAppliesForward() {
        let boundary = day(5)
        let periods = [
            StatsEngine.RatePeriod(start: .distantPast, earnRate: 0.15),
            StatsEngine.RatePeriod(start: boundary, earnRate: 1.0),
        ]
        let credited = [day(1), day(5), day(6), day(8)]
        let result = StatsEngine.computeRestBank(creditedDates: credited, ratePeriods: periods, now: day(8))

        // Confirms day 5's credit used the new 1.0 rate (bank goes from
        // -2.0 after day 4's uncredited stretch to exactly -1.0) rather
        // than the old 0.15 rate (which would land at -1.85).
        XCTAssertEqual(result.bankBalance, 0, accuracy: 1e-9)
        XCTAssertEqual(result.currentStreak, 1)
        XCTAssertEqual(result.maxStreak, 2)
    }
}
