//
//  ProgramStreakAcceptanceTests.swift
//  TheJymTests
//
//  The acceptance criteria for crediting logged rest days to the Program
//  Streak, pinned as a fixture so they live in the suite rather than in a
//  conversation.
//
//  The fixture is not invented. It is the exact day-by-day shape of the
//  real store's open streak at the time of the change, extracted from the
//  device container and transcribed as offsets from the streak's first
//  day — 62 training days, 28 activity rests, 6 logged plain rests and
//  one unlogged gap (day 27) across a 98-day span, with the phase's
//  cycle-completion resets where they actually fell.
//
//  Offsets, not dates, so it keeps meaning the same thing next year. The
//  live store will have moved on; these numbers are the ones the change
//  was accepted against:
//
//      Program Streak      90 -> 96
//      Max Program Streak  90 -> 96
//      Lift + Walk + Rest = Program, as 62 + 28 + 6 = 96
//
//  The span stays longer than the count (98 calendar days, 96 counted)
//  because the unlogged day is absorbed without being credited. That gap
//  is the thing the dateLine on those rows is still carrying.
//

import XCTest
@testable import TheJym

final class ProgramStreakAcceptanceTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func d(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: start)! }

    // Transcribed from the real store. Every offset 0...97 appears in
    // exactly one of these three lists except 27, which is the unlogged
    // day, and 97, which is "today" with nothing logged yet.
    private let trainingOffsets = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13, 15, 16, 18, 19, 21, 22, 24, 25,
                                   28, 29, 31, 32, 34, 35, 37, 38, 40, 41, 43, 44, 46, 47, 49, 50,
                                   52, 53, 55, 56, 58, 59, 61, 62, 64, 65, 67, 68, 70, 71, 73, 74,
                                   76, 77, 79, 80, 82, 84, 85, 86, 88, 89, 91, 92]
    private let activityOffsets = [2, 5, 8, 11, 17, 20, 23, 26, 30, 33, 36, 39, 42, 45, 51, 54,
                                   60, 63, 66, 69, 72, 75, 78, 81, 83, 87, 90, 93]
    private let plainRestOffsets = [14, 48, 57, 94, 95, 96]
    private let resetOffsets = [1, 8, 14, 20, 26, 33, 39, 46, 51, 57, 63, 69, 75, 81, 87, 94]

    private func bankWalk() -> StatsEngine.RestBankResult {
        StatsEngine.computeRestBank(
            trainingDates: trainingOffsets.map(d),
            activityRestDates: activityOffsets.map(d),
            plainRestDates: plainRestOffsets.map(d),
            resetEvents: resetOffsets.map { (date: d($0), resetTo: 2.0) },
            now: d(97))
    }

    /// Guards the fixture itself. If these three counts ever stop being
    /// 62/28/6 someone has edited the transcription, and every number
    /// below would move with it for a reason that has nothing to do with
    /// the engine.
    func testFixtureIsTheShapeItClaimsToBe() {
        XCTAssertEqual(trainingOffsets.count, 62)
        XCTAssertEqual(activityOffsets.count, 28)
        XCTAssertEqual(plainRestOffsets.count, 6)
        let all = Set(trainingOffsets).union(activityOffsets).union(plainRestOffsets)
        XCTAssertEqual(all.count, 96, "no offset appears in two lists")
        XCTAssertEqual(Set(0...97).subtracting(all), [27, 97],
                       "exactly one unlogged gap day, plus an unlogged today")
    }

    func testProgramStreakIs96() {
        let r = bankWalk()
        XCTAssertEqual(r.currentStreak, 96, "Program Streak: was 90 before logged rests counted")
        XCTAssertEqual(r.maxStreak, 96, "Max Program Streak: the open streak is also the record")
    }

    /// The identity the Consistency table now shows on its two banked
    /// rows. Lift + Walk come from the active-day split, Rest from the
    /// bank walk; this asserts the three still sum to the streak.
    func testLiftPlusWalkPlusRestEqualsProgram() {
        let r = bankWalk()
        let lift = trainingOffsets.count
        let walk = activityOffsets.count
        let rest = r.currentStreakRestDays
        XCTAssertEqual(rest, 6, "the six logged rests inside the streak")
        XCTAssertEqual(lift + walk + rest, r.currentStreak, "62 + 28 + 6 = 96")
        XCTAssertEqual(lift + walk + rest, 96)
        XCTAssertEqual(r.maxStreakRestDays, 6, "same streak, same rests")
    }

    /// Count and span deliberately stay different numbers: 96 counted
    /// days across a 98-day calendar span, because day 27 was unlogged
    /// and is absorbed rather than credited. If these ever become equal,
    /// something started crediting silence.
    func testTheSpanStaysLongerThanTheCount() {
        let r = bankWalk()
        guard let range = r.maxStreakRange else { return XCTFail("expected a max streak range") }
        let span = (cal.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1
        XCTAssertEqual(span, 97, "day 0 through day 96")
        XCTAssertEqual(r.currentStreak, 96)
        XCTAssertGreaterThan(span, r.currentStreak,
                             "the unlogged day is inside the span but not the count")
        XCTAssertEqual(r.currentStreakStartDate, d(0))
    }

    /// The two row kinds now genuinely differ, and the cell is what
    /// expresses that. Daily rows pass no rest and must stay blank.
    func testTheCellShowsRestOnlyForProgramRows() {
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Rest", active: 96, lift: 62, walk: 28,
                                                  rest: 6), "6")
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Rest", active: 40, lift: 30, walk: 10),
                       "\u{2014}", "a Daily streak ends at the first rest day — blank, not 0")
        XCTAssertEqual(ConsistencyStreakCell.text(header: "Rest", active: 96, lift: 62, walk: 28,
                                                  rest: 0), "0",
                       "a Program streak with no rests inside it is a real zero, not a dash")
    }
}
