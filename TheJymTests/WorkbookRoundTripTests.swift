//
//  WorkbookRoundTripTests.swift
//  TheJymTests
//
//  Real writer -> real reader -> real parser. Everything here goes through
//  XLSXWriter.makeWorkbook and XLSXReader.readSheetsByName rather than a
//  hand-built grid, because the bug that dropped 24 weigh-ins lived exactly
//  in the gap between "the grid a test writes" and "the grid the file
//  produces": XLSXWriter omits .blank cells and XLSXReader sizes a row to
//  its last populated column, so rows come back RAGGED.
//
//  A hand-built fixture can't catch that. These assert the cell counts the
//  round trip actually yields before asserting anything about parsing.
//

import XCTest
@testable import TheJym

final class WorkbookRoundTripTests: XCTestCase {

    private func roundTrip(_ sheets: [(name: String, rows: [[XLSXCell]])]) -> [String: [[String]]] {
        let data = XLSXWriter.makeWorkbook(sheets: sheets)
        guard let out = XLSXReader.readSheetsByName(data: data) else {
            XCTFail("workbook didn't read back"); return [:]
        }
        return out
    }

    // MARK: - Sheets are found by NAME

    func testAllThreeSheetsRoundTripByName() {
        let sheets = roundTrip([
            ("History", [[.string("Date"), .string("Exercise")], [.string("2026-09-15"), .string("Bench Press")]]),
            ("Exercises", [[.string("Exercise")], [.string("Bench Press")]]),
            ("Equipment", [[.string("Name")], [.string("Barbell")]]),
        ])
        XCTAssertEqual(Set(sheets.keys), ["History", "Exercises", "Equipment"],
                       "named lookup must not depend on sheet1/sheet2 ordering")
    }

    /// The reader must resolve names through workbook.xml, so a History
    /// sheet that isn't first is still found.
    func testHistoryIsFoundWhenItIsNotTheFirstSheet() {
        let sheets = roundTrip([
            ("Equipment", [[.string("Name")], [.string("Barbell")]]),
            ("History", [[.string("Date"), .string("Exercise"), .string("Sets"),
                          .string("Weights"), .string("Reps")],
                         [.string("2026-09-15"), .string("Body Weight"), .blank,
                          .number(181.4), .blank]]),
        ])
        XCTAssertNotNil(sheets["History"])
        XCTAssertEqual(sheets["History"]?.count, 2)
    }

    // MARK: - Ragged rows, measured not assumed

    /// The weigh-in shape, proven end to end: blank Sets and blank Reps
    /// mean the row comes back SHORTER than its header.
    func testWeighInRowComesBackRagged() {
        let input: [(name: String, rows: [[XLSXCell]])] = [("History", [
            [.string("Date"), .string("Exercise"), .string("Sets"), .string("Weights"), .string("Reps")],
            [.string("2026-09-15"), .string("Body Weight"), .blank, .number(181.4), .blank],
        ])]
        let sheets = roundTrip(input)
        let rows = sheets["History"]!
        XCTAssertEqual(rows[0].count, 5, "header is five columns")
        XCTAssertEqual(rows[1].count, 4,
                       "trailing blank Reps is omitted entirely — this is the 4-vs-5 that dropped every weigh-in")
        XCTAssertEqual(rows[1][3], "181.4", "weight sits at index 3, the Weights column")
    }

    /// Whatever the exporter actually emits for these two sheets, the
    /// parser must cope. Asserting the counts documents reality rather
    /// than trusting a reading of the writer.
    func testExercisesAndEquipmentRowShapes() {
        let sheets = roundTrip([
            ("Exercises", [
                [.string("Exercise"), .string("Equipment"), .string("Bodyweight"), .string("Sets"), .string("Notes")],
                [.string("Pull-Up"), .string(""), .string("Yes"), .string("5/5/5"), .string("")],
                [.string("Sparse"), .blank, .blank, .blank, .blank],
            ]),
            ("Equipment", [
                [.string("Name"), .string("Type"), .string("Weight"), .string("Sides"), .string("Dumbbell/Band Weights")],
                [.string("Barbell"), .string("Barbell"), .number(45), .number(2), .string("")],
                [.string("Dumbbells"), .string("Dumbbell/Band"), .blank, .blank, .string("10, 20, 30")],
            ]),
        ])
        for (sheet, rows) in sheets {
            for (i, row) in rows.enumerated() {
                print("\(sheet) row \(i): \(row.count) cells \(row)")
            }
        }
        // The all-blank-tail row is the hard case either way.
        XCTAssertEqual(sheets["Exercises"]![2].count, 1,
                       "a row whose only populated cell is A comes back as one cell")
    }

    // MARK: - The parsers survive ragged input

    func testLibraryAndEquipmentParseFromRaggedRows() {
        let input: [(name: String, rows: [[XLSXCell]])] = [
            ("History", [[.string("Date"), .string("Exercise"), .string("Sets"),
                          .string("Weights"), .string("Reps")]]),
            ("Exercises", [
                [.string("Exercise"), .string("Equipment"), .string("Bodyweight"), .string("Sets"), .string("Notes")],
                // No notes — trailing cell blank.
                [.string("Pull-Up"), .string("Bar"), .string("Yes"), .string("5/5/5"), .blank],
                // Name only.
                [.string("Sparse"), .blank, .blank, .blank, .blank],
            ]),
            ("Equipment", [
                [.string("Name"), .string("Type"), .string("Weight"), .string("Sides"), .string("Dumbbell/Band Weights")],
                // Barbell — no dumbbell weights, trailing cell blank.
                [.string("Barbell"), .string("Barbell"), .number(45), .number(2), .blank],
                // Dumbbells — no weight/sides, middle cells blank.
                [.string("Dumbbells"), .string("Dumbbell/Band"), .blank, .blank, .string("10, 20, 30")],
                [.blank],
                [.string("Plates Owned"), .string("45, 25, 10")],
            ]),
        ]
        let data = XLSXWriter.makeWorkbook(sheets: input)
        guard let wb = ImportEngine.parseWorkbook(xlsxData: data) else {
            return XCTFail("workbook didn't parse")
        }

        XCTAssertEqual(wb.library.count, 2, "both exercise rows survive, ragged or not")
        let pullUp = wb.library.first { $0.name == "Pull-Up" }
        XCTAssertEqual(pullUp?.equipmentName, "Bar")
        XCTAssertTrue(pullUp?.isBodyweight == true)
        XCTAssertEqual(pullUp?.setsText, "5/5/5")
        XCTAssertEqual(pullUp?.notes, "", "a missing trailing cell reads as empty, not a crash")
        let sparse = wb.library.first { $0.name == "Sparse" }
        XCTAssertNotNil(sparse, "a name-only row still imports")
        XCTAssertEqual(sparse?.setsText, "")

        XCTAssertEqual(wb.equipment.count, 2, "the blank spacer and the plates row aren't equipment")
        let bar = wb.equipment.first { $0.name == "Barbell" }
        XCTAssertEqual(bar?.weight, 45)
        XCTAssertEqual(bar?.loadableSides, 2)
        XCTAssertTrue(bar?.dumbbellWeights.isEmpty == true)
        XCTAssertFalse(bar?.isDumbbell == true)
        let db = wb.equipment.first { $0.name == "Dumbbells" }
        XCTAssertTrue(db?.isDumbbell == true)
        XCTAssertEqual(db?.dumbbellWeights, [10, 20, 30])

        XCTAssertEqual(wb.platesOwned, [45, 25, 10],
                       "the plates row is matched by name, not position — it's a 2-cell row on a 5-column sheet")
    }

    /// End to end on the shape that actually broke: a History sheet of
    /// weigh-ins and a walk, straight out of the writer.
    func testHistoryRoundTripKeepsWeighInsAndWalks() {
        let sheets: [(name: String, rows: [[XLSXCell]])] = [("History", [
            [.string("Date"), .string("Exercise"), .string("Sets"), .string("Weights"), .string("Reps")],
            [.string("2026-09-15"), .string("Body Weight"), .blank, .number(181.4), .blank],
            [.string("2026-09-15"), .string("Walk"), .string("1x1"), .number(3.1), .number(1)],
            [.string("2026-09-16"), .string("Bench Press"), .string("5/5"), .string("135/135"), .string("5/5")],
        ])]
        let data = XLSXWriter.makeWorkbook(sheets: sheets)
        guard let wb = ImportEngine.parseWorkbook(xlsxData: data, restActivityNames: ["walk"]) else {
            return XCTFail("workbook didn't parse")
        }
        XCTAssertEqual(wb.skipped.total, 0, "nothing may be silently dropped: \(wb.skipped.breakdown)")
        XCTAssertEqual(wb.historyRows.count, 3)

        var weighIns = 0, walks = 0, lifts = 0
        for row in wb.historyRows {
            switch row.kind {
            case .bodyWeight(let w):
                weighIns += 1
                XCTAssertEqual(w, 181.4, "read from Weights, not Reps")
            case .restActivity(let d, _):
                walks += 1
                XCTAssertEqual(d, 3.1)
            case .exercise:
                lifts += 1
            }
        }
        XCTAssertEqual(weighIns, 1, "a weigh-in must survive the round trip")
        XCTAssertEqual(walks, 1, "a ticked walk must stay a walk")
        XCTAssertEqual(lifts, 1)
    }

    // MARK: - The accounting invariant
    //
    // Every source row must land in EXACTLY ONE bucket: imported, or
    // skipped with a named reason. Nothing may be silently discarded.
    //
    // This is the assertion that makes the class of bug impossible rather
    // than merely fixed. Two have now shipped from the same pattern: a row
    // dropped by a length guard before the body-weight branch, and 20
    // pre-floor weigh-ins that were range-filtered AFTER the skip tally so
    // they appeared in neither column.

    private func assertFullyAccounted(_ wb: ImportEngine.Workbook, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(wb.historyRows.count + wb.skipped.total, wb.sourceRowCount,
                       "\(label): \(wb.sourceRowCount) source rows, \(wb.historyRows.count) imported, "
                       + "\(wb.skipped.total) skipped \(wb.skipped.breakdown) — every row must be in exactly one bucket",
                       file: file, line: line)
    }

    private func workbook(_ rows: [[XLSXCell]], activities: Set<String> = [],
                          from: Date? = nil, through: Date? = nil) -> ImportEngine.Workbook? {
        let header: [XLSXCell] = [.string("Date"), .string("Exercise"), .string("Sets"),
                                  .string("Weights"), .string("Reps")]
        let input: [(name: String, rows: [[XLSXCell]])] = [("History", [header] + rows)]
        return ImportEngine.parseWorkbook(xlsxData: XLSXWriter.makeWorkbook(sheets: input),
                                          restActivityNames: activities, from: from, through: through)
    }

    func testEveryRowIsAccountedForOnAMixedSheet() {
        let rows: [[XLSXCell]] = [
            [.string("2026-09-15"), .string("Body Weight"), .blank, .number(181.4), .blank],
            [.string("2026-09-15"), .string("Walk"), .string("1x1"), .number(3.1), .number(1)],
            [.string("2026-09-16"), .string("Bench Press"), .string("5/5"), .string("135/135"), .string("5/5")],
            [.string("2026-09-16"), .string(""), .blank, .blank, .blank],
            [.string("nonsense"), .string("Bench Press"), .string("5"), .string("135"), .string("5")],
            [.string("2026-09-17"), .string("Bench Press"), .string("5"), .blank, .blank],
            [.string("2026-09-18"), .string("Body Weight"), .blank, .string("junk"), .blank],
        ]
        guard let wb = workbook(rows, activities: ["walk"]) else { return XCTFail("no workbook") }
        XCTAssertEqual(wb.sourceRowCount, 7)
        assertFullyAccounted(wb, "mixed sheet")
        XCTAssertEqual(wb.historyRows.count, 3)
        XCTAssertEqual(wb.skipped.total, 4)
    }

    /// The exact shape that produced the phantom 20: rows outside the
    /// range must be COUNTED, not dropped before the tally.
    func testOutOfRangeRowsAreCountedNotVanished() {
        let rows: [[XLSXCell]] = (1...10).map { d in
            [.string(String(format: "2026-09-%02d", d)), .string("Body Weight"), .blank, .number(180), .blank]
        }
        let floor = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 8))!
        guard let wb = workbook(rows, from: floor) else { return XCTFail("no workbook") }

        XCTAssertEqual(wb.sourceRowCount, 10)
        XCTAssertEqual(wb.historyRows.count, 3, "Sept 8, 9, 10")
        XCTAssertEqual(wb.skipped.outOfRange, 7, "Sept 1-7 are excluded BY THE RANGE and must be counted as such")
        assertFullyAccounted(wb, "floor applied")
        XCTAssertTrue(wb.skipped.breakdown.contains { $0.0 == "Outside the date range" })
    }

    func testCeilingRowsAreCountedToo() {
        let rows: [[XLSXCell]] = (1...10).map { d in
            [.string(String(format: "2026-09-%02d", d)), .string("Bench Press"),
             .string("5"), .string("135"), .string("5")]
        }
        let ceiling = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 3))!
        guard let wb = workbook(rows, through: ceiling) else { return XCTFail("no workbook") }
        XCTAssertEqual(wb.historyRows.count, 3)
        XCTAssertEqual(wb.skipped.outOfRange, 7)
        assertFullyAccounted(wb, "ceiling applied")
    }

    /// Holds for arbitrary junk too — the invariant isn't fixture-shaped.
    func testAccountingHoldsForArbitraryRows() {
        let noise: [[XLSXCell]] = [
            [.string("2026-09-15"), .string("Deadlift"), .string("3"), .string("315"), .string("3")],
            [.blank],
            [.string(""), .string(""), .string(""), .string(""), .string("")],
            [.string("2026-09-15"), .string("Walk"), .blank, .number(2.0), .blank],
            [.string("2026-13-45"), .string("Bench"), .string("5"), .string("1"), .string("5")],
            [.string("2026-09-15")],
            [.string("2026-09-15"), .string("Body Weight"), .blank, .number(179.9), .blank],
            [.string("2026-09-15"), .string("Row"), .string("5"), .string("95/95"), .string("5")],
        ]
        for activities in [Set<String>(), ["walk"]] {
            for floor in [nil, Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))] {
                guard let wb = workbook(noise, activities: activities, from: floor) else {
                    return XCTFail("no workbook")
                }
                assertFullyAccounted(wb, "noise activities=\(activities) floor=\(String(describing: floor))")
                XCTAssertTrue(wb.isFullyAccounted)
            }
        }
    }

    /// sourceRowCount is the WHOLE sheet, independent of the range — the
    /// denominator of the invariant, not a post-filter count.
    ///
    /// Shaped like the real file: a large body of pre-floor history and a
    /// small in-range tail. A truncated denominator would make the
    /// invariant pass over a population that excludes exactly the rows
    /// most worth accounting for.
    func testSourceRowCountIsTheWholeFileNotTheFilteredTail() {
        var rows: [[XLSXCell]] = []
        // 1,284 pre-floor exercise rows, as in the Sept 9 snapshot.
        for i in 0..<1284 {
            let d = 1 + (i % 8)
            rows.append([.string(String(format: "2026-09-%02d", d)), .string("Bench Press"),
                         .string("5"), .string("135"), .string("5")])
        }
        // 20 pre-floor weigh-ins.
        for i in 0..<20 {
            rows.append([.string(String(format: "2026-09-%02d", 1 + (i % 8))),
                         .string("Body Weight"), .blank, .number(180), .blank])
        }
        // The tail: 122 exercise logs, 9 walks, 4 weigh-ins.
        for i in 0..<122 {
            rows.append([.string(String(format: "2026-09-%02d", 10 + (i % 20))), .string("Bench Press"),
                         .string("5"), .string("135"), .string("5")])
        }
        for i in 0..<9 {
            rows.append([.string(String(format: "2026-09-%02d", 10 + i)), .string("Walk"),
                         .string("1x1"), .number(3.1), .number(1)])
        }
        for i in 0..<4 {
            rows.append([.string(String(format: "2026-09-%02d", 11 + i * 4)),
                         .string("Body Weight"), .blank, .number(181), .blank])
        }
        XCTAssertEqual(rows.count, 1439)

        let floor = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        guard let wb = workbook(rows, activities: ["walk"], from: floor) else {
            return XCTFail("no workbook")
        }
        XCTAssertEqual(wb.sourceRowCount, 1439,
                       "the denominator must be the whole file, not the in-range tail")
        XCTAssertEqual(wb.historyRows.count, 135, "122 lifts + 9 walks + 4 weigh-ins")
        XCTAssertEqual(wb.skipped.outOfRange, 1304, "1,284 lifts + 20 weigh-ins before the floor")
        assertFullyAccounted(wb, "whole-file denominator")
    }
}
