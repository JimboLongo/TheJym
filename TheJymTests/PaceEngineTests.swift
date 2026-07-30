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
}
