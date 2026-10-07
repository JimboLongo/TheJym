//
//  XLSXExportTests.swift
//  TheJymTests
//
//  Covers XLSXWriter's hand-rolled ZIP/OOXML output: real ZIP framing, XML
//  escaping, and numeric vs. string cell typing. Manually verified once
//  against a real reader (Python's openpyxl round-tripped sheet names,
//  numeric types, blank cells, and escaped special characters correctly)
//  — these tests check the same properties structurally so a regression
//  doesn't need that manual step to catch.
//
//  Every assertion reads the part's XML back through XLSXReader's own
//  unzip. They used to grep the archive's raw bytes, which worked only
//  while entries were written uncompressed — switching the writer to
//  deflate broke all four at once. Reading through the reader is both
//  correct and strictly more useful: it exercises the deflate/inflate pair
//  on every one of these cases.
//

import XCTest
@testable import TheJym

final class XLSXExportTests: XCTestCase {

    /// A part's XML as text, unzipped.
    private func xml(_ part: String, in data: Data) throws -> String {
        let raw = try XCTUnwrap(XLSXReader.rawPart(named: part, in: data),
                                "part \(part) missing or failed to inflate")
        return String(decoding: raw, as: UTF8.self)
    }

    func testWorkbookContainsExpectedSheetNamesAndCellText() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [
            ("History", [[.string("Date"), .string("Exercise")], [.string("2026-01-05"), .string("Bench Press")]]),
            ("Exercises", [[.string("Exercise")]]),
            ("Equipment", [[.string("Name")]]),
        ])
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "should start with a ZIP local file header")

        let workbook = try xml("xl/workbook.xml", in: data)
        XCTAssertTrue(workbook.contains("name=\"History\""))
        XCTAssertTrue(workbook.contains("name=\"Exercises\""))
        XCTAssertTrue(workbook.contains("name=\"Equipment\""))
        XCTAssertTrue(try xml("xl/worksheets/sheet1.xml", in: data).contains("Bench Press"))
    }

    func testXMLEscapingRoundTripsSpecialCharacters() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.string("A & B <C> \"D\" 'E'")]])])
        XCTAssertTrue(try xml("xl/worksheets/sheet1.xml", in: data)
            .contains("A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;"))
    }

    /// Numeric cells (weights, plate sizes, etc.) should be real spreadsheet
    /// numbers — no `t="inlineStr"` type attribute, no quoting — not text,
    /// so Excel/Numbers can sum/sort/filter them.
    func testNumericCellsAreWrittenAsNumbersNotStrings() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.number(181.5), .int(45)]])])
        let sheet = try xml("xl/worksheets/sheet1.xml", in: data)
        XCTAssertTrue(sheet.contains("<v>181.5</v>"))
        XCTAssertTrue(sheet.contains("<v>45</v>"), "whole numbers print without a trailing .0")
        XCTAssertFalse(sheet.contains("t=\"inlineStr\""))
    }

    /// A `.blank` cell contributes nothing to its row -- no empty <c> tag
    /// taking up a cell reference.
    func testBlankCellsAreOmitted() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.string("A"), .blank, .string("C")]])])
        let sheet = try xml("xl/worksheets/sheet1.xml", in: data)
        XCTAssertTrue(sheet.contains("r=\"A1\""))
        XCTAssertFalse(sheet.contains("r=\"B1\""))
        XCTAssertTrue(sheet.contains("r=\"C1\""))
    }

    // MARK: - Deflate

    /// Every part is written with ZIP method 8, and the archive is
    /// materially smaller than the bytes it holds. The writer falls back to
    /// storing a part that doesn't compress, so this uses realistically
    /// repetitive content rather than one tiny cell.
    func testPartsAreDeflatedAndSmallerThanTheirContent() throws {
        let rows: [[XLSXCell]] = (0..<400).map { i in
            [.string("2026-01-05"), .string("Incline DB Bench Press"),
             .string("5/5/5"), .string("\(100 + i % 7)/\(100 + i % 7)"), .string("5/5")]
        }
        let data = XLSXWriter.makeWorkbook(sheets: [("History", rows)])
        let sheet = try XCTUnwrap(XLSXReader.rawPart(named: "xl/worksheets/sheet1.xml", in: data))

        XCTAssertLessThan(data.count, sheet.count,
                          "the whole archive should be smaller than its largest part's XML")
        XCTAssertTrue(XLSXReader.partNames(in: data).contains("xl/worksheets/sheet1.xml"))

        // The reader's own parse must still produce every row — a CRC or
        // size field describing the deflated bytes instead of the original
        // would break exactly here.
        let parsed = try XCTUnwrap(XLSXReader.readSheetsByName(data: data))
        XCTAssertEqual(parsed["History"]?.count, 400)
        XCTAssertEqual(parsed["History"]?.first?.first, "2026-01-05")
    }

    /// A deflated workbook survives the real import path end to end.
    func testDeflatedWorkbookParsesThroughImportEngine() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [
            ("History", [
                [.string("Date"), .string("Exercise"), .string("Sets"),
                 .string("Weights"), .string("Reps")],
                [.string("2026-01-05"), .string("Bench Press"), .string("5/5/5"),
                 .string("185/185/185"), .string("5/5/5")],
                [.string("2026-01-06"), .string("Body Weight"), .blank,
                 .number(181.5), .blank],
            ]),
        ])
        let wb = try XCTUnwrap(ImportEngine.parseWorkbook(xlsxData: data))
        XCTAssertEqual(wb.historyRows.count, 2)
        XCTAssertEqual(wb.skipped.total, 0)
        XCTAssertTrue(wb.isFullyAccounted)
    }

    /// Empty input can't be deflated into something valid, so the writer
    /// stores it — and the reader must still read it. Guards the per-entry
    /// fallback, which is the branch a pathological input takes.
    func testEmptyAndIncompressiblePartsStillReadBack() throws {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [])])
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(XLSXReader.rawPart(named: "xl/workbook.xml", in: data))
    }
}
