//
//  RecoveryImportTests.swift
//  TheJymTests
//
//  The two bugs that made the export a one-way trip, plus the pieces the
//  recovery import adds around them.
//
//  Both body-weight bugs are covered together on purpose: fixing the NAME
//  alone turns "imports as an exercise" into "skipped entirely", because
//  the export writes the value into Weights while the old parser read it
//  from Reps. Either half alone is still a broken round trip.
//

import XCTest
import SwiftData
@testable import TheJym

final class RecoveryImportTests: XCTestCase {
    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func dateStr(_ y: Int, _ m: Int, _ d: Int) -> String {
        Formatters.exportDate.string(from: day(y, m, d))
    }

    /// The History sheet exactly as SettingsView.historySheetRows writes it.
    private func historySheet(_ body: [[String]]) -> [[String]] {
        [["Date", "Exercise", "Sets", "Weights", "Reps"]] + body
    }

    /// The shape the EXPORT actually produces for a weigh-in. XLSXExport
    /// omits .blank cells entirely and XLSXReader sizes a row to its last
    /// populated column, so a "Body Weight" row — blank Sets, blank Reps —
    /// arrives as FOUR cells against a five-column header, not five.
    ///
    /// This is the shape the original test got wrong: it wrote "" for Reps,
    /// producing five cells, which sailed through a length guard the real
    /// file failed. 24 weigh-ins were silently skipped as a result.
    private func exportedWeighInRow(_ y: Int, _ m: Int, _ d: Int, _ weight: String) -> [String] {
        [dateStr(y, m, d), "Body Weight", "", weight]     // no fifth cell
    }

    private func parse(_ rows: [[String]], activities: Set<String> = []) -> [ImportEngine.ImportedEntry] {
        // parseFields is private; go through the public workbook path by
        // building a one-sheet grid the same way parseWorkbook does.
        ImportEngine.parseHistorySheetForTesting(rows, restActivityNames: activities)
    }

    // MARK: - Body weight: both halves

    func testBodyWeightRowInTheExportsOwnShapeImports() {
        // What the export actually writes: name "Body Weight", value in
        // Weights, Reps blank.
        let rows = historySheet([[dateStr(2026, 9, 15), "Body Weight", "", "181.4", ""]])
        let parsed = parse(rows)
        XCTAssertEqual(parsed.count, 1)
        guard case .bodyWeight(let w) = parsed[0].kind else {
            return XCTFail("imported as \(parsed[0].kind) — must be a weigh-in, not an exercise")
        }
        XCTAssertEqual(w, 181.4)
    }

    /// The regression that actually bit: a row SHORTER than the header.
    func testWeighInRowWithNoTrailingRepsCellImports() {
        let rows = historySheet([exportedWeighInRow(2026, 9, 15, "181.4")])
        XCTAssertEqual(rows[1].count, 4, "fixture must be 4 cells — that's what the export yields")
        let parsed = parse(rows)
        XCTAssertEqual(parsed.count, 1, "a short row must not be dropped for missing optional columns")
        guard case .bodyWeight(let w) = parsed[0].kind else {
            return XCTFail("imported as \(parsed[0].kind)")
        }
        XCTAssertEqual(w, 181.4)
    }

    /// A short EXERCISE row is still skipped, and says why — the guard was
    /// loosened for optional columns, not removed.
    func testSkipReasonsAreItemised() {
        let rows = historySheet([
            exportedWeighInRow(2026, 9, 15, "181.4"),          // imports
            [dateStr(2026, 9, 16), "", "", "", ""],            // no name
            ["not-a-date", "Bench Press", "5/5", "135/135", "5/5"],  // bad date
            [dateStr(2026, 9, 17), "Bench Press", "5/5", "", ""],    // no weights
            [dateStr(2026, 9, 18), "Body Weight", "", "", ""],       // unreadable weight
        ])
        let (imported, reasons) = ImportEngine.parseHistorySheetWithReasonsForTesting(rows)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(reasons.missingName, 1)
        XCTAssertEqual(reasons.unparseableDate, 1)
        XCTAssertEqual(reasons.unusableSets, 1)
        XCTAssertEqual(reasons.unreadableBodyWeight, 1)
        XCTAssertEqual(reasons.total, 4)
        XCTAssertEqual(reasons.breakdown.count, 4, "every non-zero reason is named")
    }

    func testOldWeightSpellingWithValueInRepsStillWorks() {
        // The pre-existing CSV convention, which must not regress.
        let rows = historySheet([[dateStr(2026, 9, 15), "Weight", "", "", "181.4"]])
        let parsed = parse(rows)
        XCTAssertEqual(parsed.count, 1)
        guard case .bodyWeight(let w) = parsed[0].kind else {
            return XCTFail("the old spelling must still import as a weigh-in")
        }
        XCTAssertEqual(w, 181.4)
    }

    func testBodyWeightLabelVariants() {
        // The literal string SettingsView.historySheetRows writes, space
        // and capital W included.
        XCTAssertTrue(ImportEngine.isBodyWeightLabel("Body Weight"))
        for name in ["Weight", "weight", "Body Weight", "body weight", "Bodyweight"] {
            XCTAssertTrue(ImportEngine.isBodyWeightLabel(name), "\(name) should be a weigh-in label")
        }
        for name in ["Bench Press", "Weighted Dips", "Body Saw", "Deadlift"] {
            XCTAssertFalse(ImportEngine.isBodyWeightLabel(name), "\(name) is a real exercise")
        }
    }

    // MARK: - Walks

    func testUntickedWalkImportsAsAnExercise() {
        // The pre-fix behaviour, pinned so the ticklist's purpose is clear:
        // without confirmation a walk IS a lifting log.
        let rows = historySheet([[dateStr(2026, 9, 15), "Walk", "1x1", "3.1", "1"]])
        let parsed = parse(rows)
        guard case .exercise = parsed[0].kind else {
            return XCTFail("unticked, it must stay an exercise — the user hasn't confirmed")
        }
    }

    func testTickedWalkImportsAsARestActivityWithItsDistance() {
        let rows = historySheet([[dateStr(2026, 9, 15), "Walk", "1x1", "3.1", "1"]])
        let parsed = parse(rows, activities: ["walk"])
        XCTAssertEqual(parsed.count, 1)
        guard case .restActivity(let distance, let unit) = parsed[0].kind else {
            return XCTFail("ticked, it must become a rest-day activity")
        }
        XCTAssertEqual(distance, 3.1, "the Weights cell is the distance")
        XCTAssertEqual(unit, "mi")
    }

    // MARK: - Date range

    func testDateFloorAndCeiling() {
        let rows = (10...20).map { ImportEngine.ImportedEntry(
            date: day(2026, 9, $0), exerciseName: "Bench Press",
            kind: .exercise(goalType: .fixedSets, targetReps: [5], weights: [135], reps: [5]),
            phaseNumber: nil, dayLabel: nil, equipmentName: nil) }

        XCTAssertEqual(ImportEngine.rows(rows, from: day(2026, 9, 15), through: nil).count, 6,
                       "15th through 20th, floor inclusive")
        XCTAssertEqual(ImportEngine.rows(rows, from: nil, through: day(2026, 9, 12)).count, 3,
                       "10th through 12th, ceiling inclusive")
        XCTAssertEqual(ImportEngine.rows(rows, from: day(2026, 9, 15), through: day(2026, 9, 16)).count, 2)
        XCTAssertEqual(ImportEngine.rows(rows, from: nil, through: nil).count, 11)
    }

    /// The whole point of the floor: it's the duplicate guard for an
    /// additive import with no dedup.
    func testFloorExcludesAlreadyRestoredHistory() {
        let rows = (5...12).map { ImportEngine.ImportedEntry(
            date: day(2026, 9, $0), exerciseName: "Bench Press",
            kind: .exercise(goalType: .fixedSets, targetReps: [5], weights: [135], reps: [5]),
            phaseNumber: nil, dayLabel: nil, equipmentName: nil) }
        let tail = ImportEngine.rows(rows, from: day(2026, 9, 10), through: nil)
        XCTAssertEqual(tail.count, 3, "Sept 10, 11, 12 — the Sept 9 snapshot's days are excluded")
        XCTAssertFalse(tail.contains { $0.date < day(2026, 9, 10) })
    }

    // MARK: - Preview

    func testPreviewCountsAndResolvesBodyweightSets() {
        let rows: [ImportEngine.ImportedEntry] = [
            .init(date: day(2026, 9, 11), exerciseName: "Pull-Up",
                  kind: .exercise(goalType: .fixedSets, targetReps: [8], weights: [0, 0, 0], reps: [8, 8, 8]),
                  phaseNumber: nil, dayLabel: nil, equipmentName: nil),
            .init(date: day(2026, 9, 11), exerciseName: "Walk",
                  kind: .restActivity(distance: 3.1, distanceUnit: "mi"),
                  phaseNumber: nil, dayLabel: nil, equipmentName: nil),
            .init(date: day(2026, 9, 12), exerciseName: "Body Weight",
                  kind: .bodyWeight(weight: 181.4),
                  phaseNumber: nil, dayLabel: nil, equipmentName: nil),
        ]
        // A weigh-in already in the restored store, dated BEFORE the sets.
        let p = ImportEngine.preview(rows,
                                     existingWeighIns: [(day(2026, 9, 1), 182.0)],
                                     bodyweightExerciseNames: ["Pull-Up"])
        XCTAssertEqual(p.sessions, 1,
                       "only Sept 11 carries a session — the Sept 12 weigh-in creates a BodyWeightEntry, not a WorkoutSession")
        XCTAssertEqual(p.exerciseLogs, 1)
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.weighIns, 1)
        XCTAssertEqual(p.restActivities, 1)
        XCTAssertEqual(p.bodyweightSetsResolved, 3, "the Sept 1 weigh-in resolves all three")
        XCTAssertEqual(p.bodyweightSetsUnresolved, 0)
        XCTAssertEqual(p.firstDate, day(2026, 9, 11))
        XCTAssertEqual(p.lastDate, day(2026, 9, 12))
    }

    func testPreviewReportsBodyweightSetsWithNoPriorWeighIn() {
        let rows: [ImportEngine.ImportedEntry] = [
            .init(date: day(2026, 9, 11), exerciseName: "Pull-Up",
                  kind: .exercise(goalType: .fixedSets, targetReps: [8], weights: [0, 0], reps: [8, 8]),
                  phaseNumber: nil, dayLabel: nil, equipmentName: nil)
        ]
        let p = ImportEngine.preview(rows, existingWeighIns: [],
                                     bodyweightExerciseNames: ["Pull-Up"])
        XCTAssertEqual(p.bodyweightSetsResolved, 0)
        XCTAssertEqual(p.bodyweightSetsUnresolved, 2,
                       "no weigh-in on or before — these get a nil bodyweightAtLog and drop out of Big Lifts")
    }
}
