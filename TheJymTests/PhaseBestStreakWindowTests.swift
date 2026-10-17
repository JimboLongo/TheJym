//
//  PhaseBestStreakWindowTests.swift
//  TheJymTests
//
//  The per-phase "Best Streak" on TodayView's phase detail used to have
//  three different definitions of "inside this phase" in one function:
//  training came from the phase's `sessions` relationship, while rest
//  activities and recovery credits were taken as "dated at or after this
//  phase's start" with NO ceiling, and the walk's end was the maximum of
//  all three. A closed phase therefore walked forward through every later
//  phase's rest days while still using its own reset events.
//
//  Harmless while rest days didn't count toward the streak. Not harmless
//  once they did: on the real store it inflated Phase 2's Best Streak
//  from 48 to 49 by counting a rest day logged under Phase 3.
//
//  These tests work from real model objects rather than date offsets,
//  because the thing being tested is the SCOPING, not the walk. The
//  offset fixtures in ProgramStreakAcceptanceTests cannot catch a bad
//  window — they hand the engine its inputs already filtered.
//
//  The window bounds the two REST models only. Sessions keep the stored
//  `phase` relationship as their scope — see
//  testSessionsFollowTheRelationshipNotTheWindow, and
//  RealStorePhaseScopeTests for the assertion that the two agree on real
//  data.
//
//  Sabotage: drop the ceiling from `inWindow` in
//  StatsEngine.phaseBestStreak and testAClosedPhaseIgnoresLaterRestDays
//  fails.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class PhaseBestStreakWindowTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var anchor = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: anchor)! }

    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, WorkoutSession.self, ExerciseLog.self, SetLog.self,
            RestDayActivity.self, ActiveRecovery.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A phase with a real template, because the bank depends on it:
    /// restDaysPerCycle counts the template's Rest days, and
    /// firstLoggedDate only sees sessions with a non-nil `day`. Without
    /// both, every reset is 0 and a plain rest breaks instead of
    /// counting — which would make these tests pass for the wrong
    /// reason.
    private func makePhase(_ number: Int, start: Date, active: Bool, in ctx: ModelContext) -> Phase {
        let phase = Phase(number: number, totalCycles: 4, startDate: start, isActive: active)
        ctx.insert(phase)
        for (i, name) in ["Push", "Pull", "Rest", "Rest"].enumerated() {
            let d = PhaseDay(order: i, name: name, isRest: name == "Rest")
            d.phase = phase
            ctx.insert(d)
        }
        return phase
    }

    @discardableResult
    private func train(_ phase: Phase, on date: Date, cycle: Int, in ctx: ModelContext) -> WorkoutSession {
        let s = WorkoutSession(date: date, dayLabel: "Push Day", cycleNumber: cycle)
        s.phase = phase
        s.day = phase.orderedDays.first { !$0.isRest }
        ctx.insert(s)
        let log = ExerciseLog(exerciseName: "Bench Press", targetReps: [8], order: 0)
        log.session = s
        ctx.insert(log)
        let set = SetLog(index: 0, weight: 135, reps: 8)
        set.exerciseLog = log
        ctx.insert(set)
        return s
    }

    /// Two phases back to back. Phase 1 runs days 0-3 and is closed;
    /// Phase 2 starts on day 4. A plain rest is then logged on day 4 —
    /// inside Phase 2, after Phase 1 ended.
    ///
    /// Phase 1's Best Streak must not see it. Under the old scoping it
    /// did: the rest day passed the ">= phase 1's start" filter, extended
    /// Phase 1's walk to day 4, and — now that logged rests count — added
    /// itself to Phase 1's streak.
    func testAClosedPhaseIgnoresLaterRestDays() {
        let ctx = makeContext()
        let phase1 = makePhase(1, start: day(0), active: false, in: ctx)
        let phase2 = makePhase(2, start: day(4), active: true, in: ctx)
        for i in 0...3 { train(phase1, on: day(i), cycle: 1, in: ctx) }

        let strayRest = ActiveRecovery(date: day(4), type: .rest)
        ctx.insert(strayRest)

        let r = StatsEngine.phaseBestStreak(phase: phase1, allPhases: [phase1, phase2],
                                            restActivities: [], activeRecoveries: [strayRest],
                                            now: day(10))
        XCTAssertEqual(r.maxStreak, 4, "four training days — day 4's rest belongs to Phase 2")
        XCTAssertEqual(r.maxStreakRestDays, 0, "no rest day is inside Phase 1 at all")
        XCTAssertEqual(r.maxStreakRange?.end, day(3), "Phase 1's walk stops at its own last day")
    }

    /// The same stray day DOES belong to the phase that owns it, so the
    /// fix is a ceiling and not a blanket exclusion.
    func testTheLaterPhaseDoesCountIt() {
        let ctx = makeContext()
        let phase1 = makePhase(1, start: day(0), active: false, in: ctx)
        let phase2 = makePhase(2, start: day(4), active: true, in: ctx)
        for i in 0...3 { train(phase1, on: day(i), cycle: 1, in: ctx) }
        train(phase2, on: day(4), cycle: 1, in: ctx)
        let rest = ActiveRecovery(date: day(5), type: .rest)
        ctx.insert(rest)

        let r = StatsEngine.phaseBestStreak(phase: phase2, allPhases: [phase1, phase2],
                                            restActivities: [], activeRecoveries: [rest],
                                            now: day(5))
        XCTAssertEqual(r.maxStreak, 2, "its own training day plus its own logged rest")
        XCTAssertEqual(r.maxStreakRestDays, 1)
    }

    /// A rest day dated BEFORE the phase started was already excluded by
    /// the old floor, and still is.
    func testAPhaseIgnoresRestDaysBeforeItStarted() {
        let ctx = makeContext()
        let phase = makePhase(1, start: day(5), active: true, in: ctx)
        for i in 5...7 { train(phase, on: day(i), cycle: 1, in: ctx) }
        let earlier = ActiveRecovery(date: day(2), type: .rest)
        ctx.insert(earlier)

        let r = StatsEngine.phaseBestStreak(phase: phase, allPhases: [phase],
                                            restActivities: [], activeRecoveries: [earlier],
                                            now: day(7))
        XCTAssertEqual(r.maxStreak, 3)
        XCTAssertEqual(r.maxStreakRestDays, 0)
    }

    /// Sessions are NOT windowed: `WorkoutSession.phase` is the
    /// authoritative record of membership, and a session attributed to
    /// Phase 1 but dated inside Phase 2's window still belongs to Phase
    /// 1. That is not hypothetical — 27 sessions in the real store were
    /// hand-attributed during recovery exactly because their dates
    /// didn't imply the right phase.
    ///
    /// RealStorePhaseScopeTests asserts the relationship and the window
    /// agree on the real store, so a future divergence is reported
    /// rather than silently decided here.
    func testSessionsFollowTheRelationshipNotTheWindow() {
        let ctx = makeContext()
        let phase1 = makePhase(1, start: day(0), active: false, in: ctx)
        let phase2 = makePhase(2, start: day(3), active: true, in: ctx)
        for i in 0...2 { train(phase1, on: day(i), cycle: 1, in: ctx) }
        // Attributed to Phase 1, dated after Phase 2 began.
        train(phase1, on: day(3), cycle: 1, in: ctx)

        let r = StatsEngine.phaseBestStreak(phase: phase1, allPhases: [phase1, phase2],
                                            restActivities: [], activeRecoveries: [], now: day(6))
        XCTAssertEqual(r.maxStreak, 4,
                       "the relationship says Phase 1, so day 3 counts for Phase 1")
        XCTAssertEqual(r.maxStreakRange?.end, day(3))
    }

    /// The last phase on record has no later phase to bound it, so it
    /// keeps running to its own data (or to now, while active).
    func testTheLastPhaseHasNoCeiling() {
        let ctx = makeContext()
        let phase = makePhase(1, start: day(0), active: true, in: ctx)
        for i in 0...2 { train(phase, on: day(i), cycle: 1, in: ctx) }
        let rest = ActiveRecovery(date: day(3), type: .rest)
        ctx.insert(rest)

        let r = StatsEngine.phaseBestStreak(phase: phase, allPhases: [phase],
                                            restActivities: [], activeRecoveries: [rest],
                                            now: day(3))
        XCTAssertEqual(r.maxStreak, 4, "nothing bounds it above, so day 3's rest still counts")
        XCTAssertEqual(r.maxStreakRestDays, 1)
    }
}
