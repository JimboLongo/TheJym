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
        setWeightsMoved: [200, 200, 200, 200, 200], weights: [20, 20, 20, 20, 20],
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

    // MARK: - Even pace cell (spreadsheet-ported "reps needed" formula)

    /// Real reported scenario: Safety Squats, target 145/145/145/155/155/
    /// 155 lbs x 6/7/7/5/5/5 (total 5225). After logging 5/6/6/6 in sets
    /// 1-4 (today's own total so far: 725+870+870+930 = 3395), the deficit
    /// is 5225-3395 = 1830 with 2 sets (5 sets) remaining -- average of the
    /// target's own weight at set positions 5 and 6 (155, 155) is 155, so
    /// ROUNDUP(1830/155/2) = 6.
    func testEvenPaceCellSpreadsTheDeficitAcrossRemainingSets() {
        let safetySquats = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 5225,
            setWeightsMoved: [870, 1015, 1015, 775, 775, 775],
            weights: [145, 145, 145, 155, 155, 155],
            reps: [6, 7, 7, 5, 5, 5],
            weightLabels: ["145", "145", "145", "155", "155", "155"])
        guard let cell = PaceEngine.evenPaceCellValue(target: safetySquats, loggedSoFar: 3395,
                                                       setsLoggedSoFar: 4, totalSetsToday: 6) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 6, accuracy: 1e-9)
    }

    /// Continuing the same scenario: logging only 3 reps (not 6) in set 5
    /// brings today's total to 3395 + 155*3 = 3860, deficit 5225-3860 =
    /// 1365, with exactly 1 set remaining at 155 lbs -- ROUNDUP(1365/155)
    /// = 9. On this last remaining set the average collapses to that one
    /// set's own weight, so this is also the literal number of reps
    /// needed to cross the target's total outright.
    func testEvenPaceCellOnTheLastRemainingSetIsTheLiteralWinThreshold() {
        let safetySquats = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 5225,
            setWeightsMoved: [870, 1015, 1015, 775, 775, 775],
            weights: [145, 145, 145, 155, 155, 155],
            reps: [6, 7, 7, 5, 5, 5],
            weightLabels: ["145", "145", "145", "155", "155", "155"])
        guard let cell = PaceEngine.evenPaceCellValue(target: safetySquats, loggedSoFar: 3860,
                                                       setsLoggedSoFar: 5, totalSetsToday: 6) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 9, accuracy: 1e-9)
    }

    func testEvenPaceCellNilWhenNoSetsRemain() {
        XCTAssertNil(PaceEngine.evenPaceCellValue(target: target, loggedSoFar: 1000,
                                                   setsLoggedSoFar: 5, totalSetsToday: 5))
    }

    func testEvenPaceCellNilWithoutTargetData() {
        let empty = ComparisonTarget(kind: .lastLogged, date: nil, totalWeightMoved: 0,
                                     setWeightsMoved: [], weights: [], reps: [], weightLabels: [])
        XCTAssertNil(PaceEngine.evenPaceCellValue(target: empty, loggedSoFar: 0,
                                                   setsLoggedSoFar: 0, totalSetsToday: 3))
    }

    /// A single-set target should behave the same as any other final set:
    /// the "average" of one weight is just that weight.
    func testEvenPaceCellWithASingleSetTarget() {
        let oneSet = ComparisonTarget(
            kind: .lastLogged, date: .now, totalWeightMoved: 200, setWeightsMoved: [200],
            weights: [40], reps: [5], weightLabels: ["40"])
        guard let cell = PaceEngine.evenPaceCellValue(target: oneSet, loggedSoFar: 0,
                                                       setsLoggedSoFar: 0, totalSetsToday: 1) else {
            return XCTFail("Expected a cell value")
        }
        XCTAssertEqual(cell, 5, accuracy: 1e-9) // ROUNDUP(200/40/1) = 5
    }
}
