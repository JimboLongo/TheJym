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

import XCTest
@testable import TheJym

final class XLSXExportTests: XCTestCase {
    /// Since entries are written "stored" (uncompressed), every part's XML
    /// text is literally present as plain bytes in the archive — so sheet
    /// names and cell content can be checked as substrings directly,
    /// without needing an actual unzip/XLSX reader in the test target.
    func testWorkbookContainsExpectedSheetNamesAndCellText() {
        let data = XLSXWriter.makeWorkbook(sheets: [
            ("History", [[.string("Date"), .string("Exercise")], [.string("2026-01-05"), .string("Bench Press")]]),
            ("Exercises", [[.string("Exercise")]]),
            ("Equipment", [[.string("Name")]]),
        ])
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "should start with a ZIP local file header")

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"History\""))
        XCTAssertTrue(text.contains("name=\"Exercises\""))
        XCTAssertTrue(text.contains("name=\"Equipment\""))
        XCTAssertTrue(text.contains("Bench Press"))
    }

    func testXMLEscapingRoundTripsSpecialCharacters() {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.string("A & B <C> \"D\" 'E'")]])])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;"))
    }

    /// Numeric cells (weights, plate sizes, etc.) should be real spreadsheet
    /// numbers — no `t="inlineStr"` type attribute, no quoting — not text,
    /// so Excel/Numbers can sum/sort/filter them.
    func testNumericCellsAreWrittenAsNumbersNotStrings() {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.number(181.5), .int(45)]])])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<v>181.5</v>"))
        XCTAssertTrue(text.contains("<v>45</v>"), "whole numbers print without a trailing .0")
        XCTAssertFalse(text.contains("t=\"inlineStr\""))
    }

    /// A `.blank` cell contributes nothing to its row -- no empty <c> tag
    /// taking up a cell reference.
    func testBlankCellsAreOmitted() {
        let data = XLSXWriter.makeWorkbook(sheets: [("Sheet", [[.string("A"), .blank, .string("C")]])])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("r=\"A1\""))
        XCTAssertFalse(text.contains("r=\"B1\""))
        XCTAssertTrue(text.contains("r=\"C1\""))
    }
}
