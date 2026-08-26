//
//  ImportTemplateTests.swift
//  TheJymTests
//
//  Covers ImportEngine.parseTemplateRows — the plain Day/Exercise/Set
//  phase-template format (no Date/Weights/Reps) used by PhaseBuilderView's
//  "Import from CSV or Excel…" button in the One Cycle section.
//

import XCTest
@testable import TheJym

final class ImportTemplateTests: XCTestCase {
    func testConsecutiveRowsWithSameDayLabelGroupIntoOneDay() {
        let csv = """
        Day,Exercise,Set
        Upper A,Bench Press,5/5/5/3/3/3
        Upper A,Barbell Row,8/8/8/8
        Lower A,Back Squat,5/5/5/3/3
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?.map(\.name), ["Upper A", "Lower A"])
        XCTAssertEqual(days?[0].exercises.map(\.name), ["Bench Press", "Barbell Row"])
        XCTAssertEqual(days?[0].exercises[0].targetReps, [5, 5, 5, 3, 3, 3])
        XCTAssertEqual(days?[1].exercises.map(\.name), ["Back Squat"])
    }

    func testRestLabelCreatesARestDayWithNoExercisesIgnoringBlankColumns() {
        let csv = """
        Day,Exercise,Set
        Upper A,Bench Press,5/5/5
        Rest,,
        Lower A,Back Squat,5/5/5
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?.map { ($0.name, $0.isRest) }.map { "\($0.0):\($0.1)" },
                       ["Upper A:false", "Rest:true", "Lower A:false"])
        XCTAssertEqual(days?[1].exercises.count, 0)
    }

    func testTwoSeparateRestRowsStayAsTwoDistinctDaysNotMerged() {
        let csv = """
        Day,Exercise,Set
        Upper A,Bench Press,5/5/5
        Rest,,
        Lower A,Back Squat,5/5/5
        Rest,,
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?.filter(\.isRest).count, 2, "each Rest row should be its own day, not merged")
        XCTAssertEqual(days?.count, 4)
    }

    func testSetColumnWrittenAsTotalParsesAsRepTotalGoal() {
        let csv = """
        Day,Exercise,Set
        Pull A,Pull-Up,40 total
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        guard case .repTotal(let target) = days?[0].exercises.first?.goalType else {
            return XCTFail("expected a repTotal goal")
        }
        XCTAssertEqual(target, 40)
    }

    func testOptionalWeightColumnSeedsStartingWeights() {
        let csv = """
        Day,Exercise,Set,Weight
        Upper A,Bench Press,5/5/5,135/135/145
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?[0].exercises.first?.weights, [135, 135, 145])
    }

    func testMissingWeightColumnLeavesWeightsEmpty() {
        let csv = """
        Day,Exercise,Set
        Upper A,Bench Press,5/5/5
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?[0].exercises.first?.weights, [])
    }

    func testPresenceOfDateColumnDefersToTheFullHistoricalFormat() {
        let csv = """
        Date,Day,Exercise,Set
        2026-01-05,Upper A,Bench Press,5/5/5
        """
        XCTAssertNil(ImportEngine.parseTemplateRows(csv: csv),
                     "a Date column means this is the full historical format, not a plain template")
    }

    func testMissingRequiredColumnReturnsNil() {
        let csv = """
        Day,Exercise
        Upper A,Bench Press
        """
        XCTAssertNil(ImportEngine.parseTemplateRows(csv: csv))
    }

    func testRowWithBlankDayIsSkipped() {
        let csv = """
        Day,Exercise,Set
        ,Bench Press,5/5/5
        Upper A,Barbell Row,8/8/8
        """
        let days = ImportEngine.parseTemplateRows(csv: csv)
        XCTAssertEqual(days?.map(\.name), ["Upper A"])
    }
}
