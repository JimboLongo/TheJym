//
//  PaceEngineTests.swift
//  TheJymTests
//
//  Verifies the pro-rata pace milestone math against a hand-traced example:
//  a target that moved 200 lbs in each of 5 sets (1000 total). By its own
//  set 3, it had moved 60% of its total, so the set-3 milestone is 60% of
//  (total + 1) = 600.6. Also checks the "n beyond the target's own set
//  count" fallback (milestone = total + 1) and the sign convention (a
//  negative cell means already ahead of pace).
//

import XCTest
@testable import TheJym

final class PaceEngineTests: XCTestCase {
    private let target = ComparisonTarget(
        kind: .lastLogged, date: .now, totalWeightMoved: 1000,
        setWeightsMoved: [200, 200, 200, 200, 200],
        reps: [10, 10, 10, 10, 10], weightLabels: ["20", "20", "20", "20", "20"])

    func testMilestoneAtSetIndexWithinTargetsOwnSetCount() {
        // Through set 3: cumulative 600, share 0.6 of 1000 -> 0.6 * 1001 = 600.6
        XCTAssertEqual(PaceEngine.milestone(atSetIndex: 3, setWeightsMoved: target.setWeightsMoved,
                                            total: target.totalWeightMoved), 600.6, accuracy: 1e-9)
    }

    func testMilestoneBeyondTargetsOwnSetCountIsFullWinThreshold() {
        XCTAssertEqual(PaceEngine.milestone(atSetIndex: 8, setWeightsMoved: target.setWeightsMoved,
                                            total: target.totalWeightMoved), 1001, accuracy: 1e-9)
    }

    func testPaceCellValueBehindPace() {
        // At set 3, milestone 600.6; only 500 logged through sets 1-2; set-3 weight 50.
        guard let cell = PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 500, columnWeight: 50) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, (600.6 - 500) / 50, accuracy: 1e-9)
        XCTAssertGreaterThan(cell, 0, "Behind pace should be positive (reps still needed)")
    }

    func testPaceCellValueAheadOfPaceIsNegative() {
        // Same milestone, but already moved 650 through sets 1-2 — past it.
        guard let cell = PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 650, columnWeight: 50) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, (600.6 - 650) / 50, accuracy: 1e-9)
        XCTAssertLessThan(cell, 0, "Ahead of pace should be negative")
    }

    func testPaceCellValueNilWithoutAColumnWeight() {
        XCTAssertNil(PaceEngine.paceCellValue(target: target, setIndex: 3, loggedSoFar: 500, columnWeight: 0))
    }

    // MARK: - Ratcheted pace cell (monotonic across sets)

    private let ratchetTarget = ComparisonTarget(
        kind: .lastLogged, date: .now, totalWeightMoved: 200,
        setWeightsMoved: [100, 100], reps: [2, 2], weightLabels: ["50", "50"])

    func testRatchetedPaceCellClampsDownAfterMeetingRequirement() {
        // Set 1 needed 3 (raw ceil of 2.01) and got exactly 3 -- met it.
        let logged = [PaceEngine.LoggedSetEntry(rawWeight: 50, effectiveWeightMoved: 150, reps: 3)]
        // Unclamped, a much lighter set-2 weight would raw out to needing 6
        // reps -- but since set 1 was met, set 2 must not demand more than 3.
        guard let cell = PaceEngine.ratchetedPaceCellValue(target: ratchetTarget, loggedSets: logged,
                                                           upcomingSetIndex: 2, upcomingRawWeight: 10) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 3, accuracy: 1e-9)
    }

    func testRatchetedPaceCellClampsUpAfterFallingShort() {
        // Set 1 needed 3 but only got 1 -- fell short.
        let logged = [PaceEngine.LoggedSetEntry(rawWeight: 50, effectiveWeightMoved: 50, reps: 1)]
        // Unclamped, a much heavier set-2 weight would raw out to needing
        // only 2 reps -- but since set 1 fell short, set 2 must not demand
        // fewer than 3.
        guard let cell = PaceEngine.ratchetedPaceCellValue(target: ratchetTarget, loggedSets: logged,
                                                           upcomingSetIndex: 2, upcomingRawWeight: 100) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 3, accuracy: 1e-9)
    }

    func testRatchetedPaceCellNilWithoutAnUpcomingWeight() {
        XCTAssertNil(PaceEngine.ratchetedPaceCellValue(target: ratchetTarget, loggedSets: [],
                                                       upcomingSetIndex: 1, upcomingRawWeight: 0))
    }

    /// Reproduces a real reported bug: Low Incline DB Press, previous
    /// workout 12/9/5 reps @ 25/30/35. Set 1 needed 13 and got exactly 13
    /// (met); set 2 needed 9 (a lighter requirement than set 1's 13, since
    /// it's a different weight) and got exactly 9 (also met). Set 3 should
    /// then need 5 -- just enough to beat the 745 lb total outright -- not
    /// 13, which is what a version of the ratchet that compared set 2's 9
    /// reps against set 1's 13-rep requirement (instead of set 2's own
    /// 9-rep requirement) incorrectly produced.
    func testRatchetDoesNotCompareASetAgainstADifferentSetsRequirement() {
        let set1: Double = 300   // 25 lbs x 12 reps
        let set2: Double = 270   // 30 lbs x 9 reps
        let set3: Double = 175   // 35 lbs x 5 reps
        let total: Double = 745
        let previousWorkout = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: total,
            setWeightsMoved: [set1, set2, set3],
            reps: [12, 9, 5], weightLabels: ["25", "30", "35"])
        let logged = [
            PaceEngine.LoggedSetEntry(rawWeight: 25, effectiveWeightMoved: 325, reps: 13),
            PaceEngine.LoggedSetEntry(rawWeight: 30, effectiveWeightMoved: 270, reps: 9),
        ]
        guard let cell = PaceEngine.ratchetedPaceCellValue(target: previousWorkout, loggedSets: logged,
                                                           upcomingSetIndex: 3, upcomingRawWeight: 35) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 5, accuracy: 1e-9)
    }

    /// The clamp applies whether or not the weight changed -- reuses the
    /// exact numbers from testRatchetedPaceCellClampsUpAfterFallingShort
    /// (set 1 needed 3, got 1, fell short) but treats set 2 as the
    /// target's own last set. Unclamped, set 2 at 100 lbs only needs 2
    /// reps to cross the win threshold (201); without isFinalSet the
    /// ordinary "fell short, can't ask for less" clamp would force it up
    /// to 3, overstating what's actually needed to win.
    func testFinalSetIgnoresTheClamp() {
        let logged = [PaceEngine.LoggedSetEntry(rawWeight: 50, effectiveWeightMoved: 50, reps: 1)]
        guard let cell = PaceEngine.ratchetedPaceCellValue(target: ratchetTarget, loggedSets: logged,
                                                           upcomingSetIndex: 2, upcomingRawWeight: 100,
                                                           isFinalSet: true) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 2, accuracy: 1e-9)
    }

    /// Reproduces a real reported bug: Safety Squats, target 145/145/145/
    /// 155/155/155 lbs x 6/7/7/5/5/5 (total 5225). Logging 5/8/9/4 in sets
    /// 1-4 correctly showed "need 4" for set 4 at 155 lbs and it was hit
    /// exactly. Set 5 is also 155 lbs -- same weight, and the set before it
    /// was just met -- so per the "just hit it, can't demand more" rule it
    /// must not ask for more than 4 either, even though the raw pro-rata
    /// math (which doesn't know about the ratchet) would want 5. Set 6 is
    /// 155 lbs too and is ALSO the true final set: this is the one place
    /// the same "just hit it" rule has to be overridden by isFinalSet,
    /// since only the literal win-threshold math (6) is actually correct
    /// there -- clamping it down to 4 like set 5 would tell the lifter 4
    /// reps are enough to win when they're 155 lbs short of the total.
    func testRatchetNeverIncreasesAfterAHitAtTheSameWeightExceptOnTheFinalSet() {
        let target = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 5225,
            setWeightsMoved: [870, 1015, 1015, 775, 775, 775],
            reps: [6, 7, 7, 5, 5, 5],
            weightLabels: ["145", "145", "145", "155", "155", "155"])
        let throughSet4 = [
            PaceEngine.LoggedSetEntry(rawWeight: 145, effectiveWeightMoved: 725, reps: 5),
            PaceEngine.LoggedSetEntry(rawWeight: 145, effectiveWeightMoved: 1160, reps: 8),
            PaceEngine.LoggedSetEntry(rawWeight: 145, effectiveWeightMoved: 1305, reps: 9),
            PaceEngine.LoggedSetEntry(rawWeight: 155, effectiveWeightMoved: 620, reps: 4),
        ]
        guard let needForSet5 = PaceEngine.ratchetedPaceCellValue(target: target, loggedSets: throughSet4,
                                                                   upcomingSetIndex: 5, upcomingRawWeight: 155) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(needForSet5, 4, accuracy: 1e-9)

        let throughSet5 = throughSet4 + [
            PaceEngine.LoggedSetEntry(rawWeight: 155, effectiveWeightMoved: 620, reps: 4),
        ]
        guard let needForSet6 = PaceEngine.ratchetedPaceCellValue(target: target, loggedSets: throughSet5,
                                                                   upcomingSetIndex: 6, upcomingRawWeight: 155,
                                                                   isFinalSet: true) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(needForSet6, 6, accuracy: 1e-9)
    }
}
