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
//  SECOND SURFACE. TodayView's phase detail shows "Best Streak — N days"
//  from the same engine, scoped to one phase and its own reset events, so
//  it inherits the rule too and the all-history figures say nothing about
//  it. The three phase-scoped cases below are that screen, transcribed
//  the same way:
//
//      Phase 1   44 -> 45   1 logged rest inside the record
//      Phase 2   46 -> 49   3
//      Phase 3    0 ->  2   2
//
//  Phase 3 is the interesting one and is kept deliberately: it has no
//  training and no activity at all, so its entire Best Streak is logged
//  rest days — and its first day is a rest that breaks against an empty
//  bank before the phase-start reset lands, which is why it reads 2 and
//  not 3.
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

    // MARK: - TodayView's per-phase "Best Streak"

    /// Each phase walked with its OWN reset events, the way
    /// TodayView.bestStreak does. A closed phase is bounded at the last
    /// logged day it can see rather than at today.
    private func phaseBest(training: [Int], activity: [Int], plain: [Int],
                           resets: [Int], span: Int) -> StatsEngine.RestBankResult {
        StatsEngine.computeRestBank(
            trainingDates: training.map(d),
            activityRestDates: activity.map(d),
            plainRestDates: plain.map(d),
            resetEvents: resets.map { (date: d($0), resetTo: 2.0) },
            now: d(span))
    }

    func testPhase1BestStreakIs45() {
        let r = phaseBest(
            training: [0, 2, 6, 7, 9, 10, 12, 13, 15, 16, 18, 19, 21, 22, 24, 25, 27, 28, 30, 31,
                       34, 35, 37, 38, 40, 41, 43, 44, 46, 47, 49, 50],
            activity: [3, 8, 11, 14, 17, 23, 26, 29, 32, 36, 39, 42, 45, 48, 51, 57, 60, 66, 69,
                       72, 75, 78, 81, 84, 87, 89, 93, 96, 99],
            plain: [1, 4, 5, 20, 54, 63, 100, 101, 102],
            resets: [0, 7, 14, 20, 26, 32, 39, 45], span: 102)
        XCTAssertEqual(r.maxStreak, 45, "Best Streak on Phase 1: was 44")
        XCTAssertEqual(r.maxStreakRestDays, 1, "one logged rest inside the record run")
    }

    func testPhase2BestStreakIs49() {
        let r = phaseBest(
            training: [0, 1, 3, 4, 6, 7, 9, 10, 12, 13, 15, 16, 18, 19, 21, 22, 24, 25, 27, 28,
                       30, 31, 33, 34, 36, 38, 39, 40, 42, 43, 45, 46],
            activity: [5, 8, 14, 17, 20, 23, 26, 29, 32, 35, 37, 41, 44, 47],
            plain: [2, 11, 48, 49, 50],
            resets: [0, 5, 11, 17, 23, 29, 35, 41], span: 50)
        XCTAssertEqual(r.maxStreak, 49, "Best Streak on Phase 2: was 46")
        XCTAssertEqual(r.maxStreakRestDays, 3)
    }

    /// A phase whose every counted day is a logged rest — no training, no
    /// activity. Worth keeping exactly as it is: it is the shape that
    /// makes the new rule most visible, and it also pins the break-order
    /// case on a real screen. Day 0 is a rest against an empty bank, so
    /// it breaks BEFORE the phase-start reset lands and takes no credit
    /// for itself; days 1 and 2 are then affordable and count. Hence 2,
    /// not 3.
    func testPhase3BestStreakIs2AndIsAllRest() {
        let r = phaseBest(training: [], activity: [], plain: [0, 1, 2], resets: [0], span: 3)
        XCTAssertEqual(r.maxStreak, 2, "Best Streak on Phase 3: was 0")
        XCTAssertEqual(r.maxStreakRestDays, 2, "both counted days are logged rests")
        XCTAssertEqual(r.maxStreakRange?.start, d(0),
                       "the reset reopens the ledger on day 0 even though day 0 took no credit")
        XCTAssertEqual(r.maxStreakRange?.end, d(2))
    }

    // MARK: - The cell

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
