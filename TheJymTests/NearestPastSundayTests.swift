//
//  NearestPastSundayTests.swift
//  TheJym
//
//  Verifies Formatters.nearestPastSunday: weight is only ever logged to the
//  most recent Sunday on or before a given date — same-day for a Sunday
//  itself, walking back the right number of days otherwise.
//

import XCTest
@testable import TheJym

final class NearestPastSundayTests: XCTestCase {
    private let cal = Calendar.current

    private func date(year: Int, month: Int, day: Int) -> Date {
        DateComponents(calendar: cal, year: year, month: month, day: day).date!
    }

    func testSundayItselfIsUnchanged() {
        // 2026-08-02 is a Sunday.
        let sunday = date(year: 2026, month: 8, day: 2)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastSunday(from: sunday), inSameDayAs: sunday))
    }

    func testWednesdayWalksBackToThatWeeksSunday() {
        // 2026-08-05 is a Wednesday; that week's Sunday is 2026-08-02.
        let wednesday = date(year: 2026, month: 8, day: 5)
        let expected = date(year: 2026, month: 8, day: 2)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastSunday(from: wednesday), inSameDayAs: expected))
    }

    func testSaturdayWalksBackOneDay() {
        // 2026-08-08 is a Saturday; the Sunday before it is 2026-08-02.
        let saturday = date(year: 2026, month: 8, day: 8)
        let expected = date(year: 2026, month: 8, day: 2)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastSunday(from: saturday), inSameDayAs: expected))
    }
}
