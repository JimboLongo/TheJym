//
//  DayAttributionTests.swift
//  TheJymTests
//
//  The repair for the Oct 2026 recovery: 27 real sessions imported with
//  no PhaseDay, which fill no cycle slot until they get one.
//
//  The fixture reproduces the actual tail — Phase 1 ending before Phase 2
//  begins, a 2025 CSV bulk far earlier, 18 training sessions on Phase 2's
//  real four-day rotation and 9 logged walks on the rest days — so the
//  projected cycle count here is the one the device will show.
//

import XCTest
import SwiftData
@testable import TheJym

@MainActor
final class DayAttributionTests: XCTestCase {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: Phase.self, PhaseDay.self, PlannedExercise.self, WorkoutSession.self,
            ExerciseLog.self, SetLog.self, RestDayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// Phase 2's real split and plans.
    private let plans: [(String, Bool, [String])] = [
        ("Lower Day 1", false, ["Safety Squats", "Heel-Elevated Goblet Squats", "BB Romanian Deadlifts",
                                "Leg Extensions", "Standing BB Calf Raises", "Hanging Leg Raises"]),
        ("Upper Day 1", false, ["Incline DB Bench Press", "Seal Rows", "Neutral-Grip Pull-Ups",
                                "Seated DB Shoulder Press", "Cable Lateral Raises",
                                "Incline DB Curls", "OH Rope Tri Extensions"]),
        ("Rest", true, []),
        ("Lower Day 2", false, ["Trap Bar Deadlifts", "Deficit Trap Bar Deadlifts", "Bulgarian DB Split Squat",
                                "Back Extensions", "Lying Leg Curls", "Seated Calf Raises",
                                "Tall Kneeling Cable Crunches"]),
        ("Upper Day 2", false, ["Bench Press", "MAG-Grip Lat Pulldowns", "Landmine Meadows Row",
                                "Cable Fly (Low-to-High)", "DB Lateral Raises",
                                "One-Arm Cable Rear Delt Flys", "EZ Bar Bicep Curls", "Tri Pushdowns"]),
        ("Rest", true, []),
    ]

    @discardableResult
    private func makePhase(_ number: Int, start: Date, ctx: ModelContext) -> Phase {
        let phase = Phase(number: number, totalCycles: 8, startDate: start)
        ctx.insert(phase)
        for (order, spec) in plans.enumerated() {
            let day = PhaseDay(order: order, name: spec.0, isRest: spec.1)
            day.phase = phase
            ctx.insert(day)
            for (i, name) in spec.2.enumerated() {
                let pe = PlannedExercise(order: i, exerciseName: name, targetReps: [5])
                pe.day = day
                ctx.insert(pe)
            }
        }
        return phase
    }

    @discardableResult
    private func session(_ d: Date, exercises: [String], ctx: ModelContext,
                         walk: Bool = false) -> WorkoutSession {
        let s = WorkoutSession(date: d, dayLabel: walk ? "Rest Day" : "Imported", cycleNumber: 0)
        ctx.insert(s)
        if walk {
            let activity = RestDayActivity(date: d, name: "Walk", distance: 3.1)
            ctx.insert(activity)
            let log = ExerciseLog(exerciseName: "Walk", targetReps: [], order: 0)
            log.session = s
            log.restDayActivity = activity
            ctx.insert(log)
        }
        for (i, name) in exercises.enumerated() {
            let log = ExerciseLog(exerciseName: name, targetReps: [5], order: i)
            log.session = s
            ctx.insert(log)
        }
        return s
    }

    /// The real tail, date for date and day for day, read off the device
    /// container rather than approximated: 18 training sessions on an
    /// L2 -> U2 -> L1 -> U1 rotation and 9 logged walks between them.
    ///
    /// The exact dates matter. An earlier version of this fixture
    /// alternated train/walk every day, which gave 13 and 13 instead of
    /// 18 and 9 and therefore projected a cycle count that had nothing to
    /// do with the device.
    private func buildTail(_ ctx: ModelContext) -> [WorkoutSession] {
        let l2 = ["Trap Bar Deadlifts", "Bulgarian DB Split Squat", "Back Extensions",
                  "Lying Leg Curls", "Seated Calf Raises", "Tall Kneeling Cable Crunches"]
        let training: [(Int, Int, [String])] = [
            (9, 11, l2), (9, 12, plans[4].2), (9, 14, plans[0].2), (9, 15, plans[1].2),
            (9, 17, l2), (9, 18, plans[4].2), (9, 20, plans[0].2), (9, 21, plans[1].2),
            (9, 23, l2), (9, 24, plans[4].2), (9, 26, plans[0].2), (9, 27, plans[1].2),
            (9, 29, l2), (9, 30, plans[4].2), (10, 2, plans[0].2), (10, 4, plans[1].2),
            (10, 5, l2), (10, 6, plans[4].2),
        ]
        let walks: [(Int, Int)] = [(9, 10), (9, 13), (9, 16), (9, 19), (9, 22),
                                   (9, 25), (9, 28), (10, 1), (10, 3)]

        var out: [WorkoutSession] = []
        for (m, d, exercises) in training {
            out.append(session(date(2026, m, d), exercises: exercises, ctx: ctx))
        }
        for (m, d) in walks {
            out.append(session(date(2026, m, d), exercises: [], ctx: ctx, walk: true))
        }
        return out
    }

    // MARK: - Scoping

    func testCandidatesAreWindowedToTheirOwnPhase() {
        let ctx = makeContext()
        let p1 = makePhase(1, start: date(2026, 7, 6), ctx: ctx)
        let p2 = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        // The 2025 CSV bulk — days never recorded, must never be proposed.
        let old = session(date(2025, 3, 1), exercises: ["Bench Press"], ctx: ctx)
        // One inside Phase 1's window, one inside Phase 2's.
        let inP1 = session(date(2026, 7, 20), exercises: ["Bench Press"], ctx: ctx)
        let inP2 = session(date(2026, 9, 11), exercises: ["Bench Press"], ctx: ctx)
        try? ctx.save()

        let all = [old, inP1, inP2]
        let c1 = DayAttributionEngine.withAllSessions(all) {
            DayAttributionEngine.candidates(for: p1, in: [p1, p2])
        }
        let c2 = DayAttributionEngine.withAllSessions(all) {
            DayAttributionEngine.candidates(for: p2, in: [p1, p2])
        }
        XCTAssertEqual(c1.map(\.date), [date(2026, 7, 20)],
                       "Phase 1 takes only its own window — not the 2025 bulk, not Phase 2's dates")
        XCTAssertEqual(c2.map(\.date), [date(2026, 9, 11)])
        XCTAssertFalse(c1.contains { $0.date < date(2026, 7, 6) })
        XCTAssertFalse(c2.contains { $0.date < date(2026, 8, 27) })
    }

    func testAlreadyAttributedSessionsAreNotCandidates() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let s = session(date(2026, 9, 11), exercises: ["Bench Press"], ctx: ctx)
        s.day = p.orderedDays[0]
        try? ctx.save()
        let c = DayAttributionEngine.withAllSessions([s]) {
            DayAttributionEngine.candidates(for: p, in: [p])
        }
        XCTAssertTrue(c.isEmpty, "a session that already has a day is left alone")
    }

    // MARK: - Matching

    func testTrainingSessionsMatchTheirPlannedDay() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let u2 = session(date(2026, 9, 12), exercises: plans[4].2, ctx: ctx)
        let l1 = session(date(2026, 9, 14), exercises: plans[0].2, ctx: ctx)
        try? ctx.save()

        let props = DayAttributionEngine.propose(for: p, sessions: [u2, l1])
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props[0].day.name, "Upper Day 2")
        XCTAssertEqual(props[0].strengthText, "8/8", "a full match")
        XCTAssertFalse(props[0].isWeak)
        XCTAssertEqual(props[1].day.name, "Lower Day 1")
        XCTAssertFalse(props[1].isCertain, "a training match is a score, not a fact")
    }

    /// Lower Day 2 plans 7 but only 6 were ever logged (Deficit Trap Bar
    /// Deadlifts never appears) — it must still match, and look weaker.
    func testPartialMatchIsProposedButMarkedWeak() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let partial = session(date(2026, 9, 11), exercises: [
            "Trap Bar Deadlifts", "Bulgarian DB Split Squat", "Back Extensions",
            "Lying Leg Curls", "Seated Calf Raises", "Tall Kneeling Cable Crunches"], ctx: ctx)
        try? ctx.save()

        let props = DayAttributionEngine.propose(for: p, sessions: [partial])
        XCTAssertEqual(props.first?.day.name, "Lower Day 2")
        XCTAssertEqual(props.first?.strengthText, "6/7")
        XCTAssertTrue(props.first?.isWeak == true, "6 of 7 must read weaker than 8 of 8")
    }

    func testWalksGoToRestSlotsAtFullConfidence() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let w1 = session(date(2026, 9, 10), exercises: [], ctx: ctx, walk: true)
        let w2 = session(date(2026, 9, 13), exercises: [], ctx: ctx, walk: true)
        try? ctx.save()

        let props = DayAttributionEngine.propose(for: p, sessions: [w1, w2])
        XCTAssertEqual(props.count, 2)
        XCTAssertTrue(props.allSatisfy { $0.isCertain }, "a logged rest activity IS a rest day")
        XCTAssertTrue(props.allSatisfy { $0.day.isRest })
        XCTAssertNotEqual(props[0].day.persistentModelID, props[1].day.persistentModelID,
                          "consecutive walks must fill DIFFERENT rest slots — a cycle needs both")
    }

    func testASessionMatchingNothingIsNotProposed() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let odd = session(date(2026, 9, 11), exercises: ["Underwater Basket Weaving"], ctx: ctx)
        try? ctx.save()
        XCTAssertTrue(DayAttributionEngine.propose(for: p, sessions: [odd]).isEmpty,
                      "no evidence means no proposal, not a guess")
    }

    // MARK: - Projection, on the real tail

    func testProjectedCycleCountOnTheRealTail() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let tail = buildTail(ctx)
        try? ctx.save()

        let candidates = DayAttributionEngine.withAllSessions(tail) {
            DayAttributionEngine.candidates(for: p, in: [p])
        }
        let props = DayAttributionEngine.propose(for: p, sessions: candidates)
        let projection = DayAttributionEngine.project(phase: p, applying: props)

        print("TAIL: \(tail.count) sessions, \(props.count) proposed")
        print("PROJECTION: slots \(projection.filledBefore) -> \(projection.filledAfter) of \(projection.totalSlots), "
              + "cycle \(projection.cycleBefore) -> \(projection.cycleAfter) of 8")

        XCTAssertEqual(tail.count, 27, "18 training sessions + 9 walks")
        XCTAssertEqual(props.count, 27, "every tail session gets a proposal")
        XCTAssertGreaterThan(projection.filledAfter, projection.filledBefore)
        XCTAssertGreaterThan(projection.cycleAfter, projection.cycleBefore)
    }

    // MARK: - Apply and undo

    func testApplySetsPhaseDayAndLabelButNotCycleNumber() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let s = session(date(2026, 9, 12), exercises: plans[4].2, ctx: ctx)
        try? ctx.save()
        let props = DayAttributionEngine.propose(for: p, sessions: [s])
        DayAttributionEngine.apply(props, to: p, context: ctx)

        XCTAssertEqual(s.phase?.number, 2)
        XCTAssertEqual(s.day?.name, "Upper Day 2")
        XCTAssertEqual(s.dayLabel, "Upper Day 2", "dayLabel follows the day")
        XCTAssertEqual(s.cycleNumber, 0,
                       "left for repairMissingCycleNumbers, so the derivation lives in one place")
    }

    func testUndoRestoresEveryPriorValue() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let s = session(date(2026, 9, 12), exercises: plans[4].2, ctx: ctx)
        try? ctx.save()

        let props = DayAttributionEngine.propose(for: p, sessions: [s])
        let snapshot = DayAttributionEngine.apply(props, to: p, context: ctx)
        XCTAssertNotNil(s.day)

        DayAttributionEngine.revert(snapshot, context: ctx)
        XCTAssertNil(s.day, "undo puts the day back to nil")
        XCTAssertNil(s.phase)
        XCTAssertEqual(s.cycleNumber, 0)
    }

    func testUntickingASessionLowersTheProjection() {
        let ctx = makeContext()
        let p = makePhase(2, start: date(2026, 8, 27), ctx: ctx)
        let tail = buildTail(ctx)
        try? ctx.save()
        let candidates = DayAttributionEngine.withAllSessions(tail) {
            DayAttributionEngine.candidates(for: p, in: [p])
        }
        let all = DayAttributionEngine.propose(for: p, sessions: candidates)
        let fewer = Array(all.dropLast(6))
        XCTAssertLessThan(DayAttributionEngine.project(phase: p, applying: fewer).filledAfter,
                          DayAttributionEngine.project(phase: p, applying: all).filledAfter,
                          "the projection must respond to what's actually selected")
    }
}
