//
//  NearestPastMondayTests.swift
//  TheJym
//
//  Verifies Formatters.nearestPastMonday: weight is only ever logged to the
//  most recent Monday on or before a given date — same-day for a Monday
//  itself, walking back the right number of days otherwise, including a
//  Sunday (the last day of a Monday-Sunday week) walking back to that same
//  week's Monday rather than forward to the next one.
//

import XCTest
@testable import TheJym

final class NearestPastMondayTests: XCTestCase {
    private let cal = Calendar.current

    private func date(year: Int, month: Int, day: Int) -> Date {
        DateComponents(calendar: cal, year: year, month: month, day: day).date!
    }

    func testMondayItselfIsUnchanged() {
        // 2026-08-03 is a Monday.
        let monday = date(year: 2026, month: 8, day: 3)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastMonday(from: monday), inSameDayAs: monday))
    }

    func testWednesdayWalksBackToThatWeeksMonday() {
        // 2026-08-05 is a Wednesday; that week's Monday is 2026-08-03.
        let wednesday = date(year: 2026, month: 8, day: 5)
        let expected = date(year: 2026, month: 8, day: 3)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastMonday(from: wednesday), inSameDayAs: expected))
    }

    func testSaturdayWalksBackToThatWeeksMonday() {
        // 2026-08-08 is a Saturday; that week's Monday is 2026-08-03.
        let saturday = date(year: 2026, month: 8, day: 8)
        let expected = date(year: 2026, month: 8, day: 3)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastMonday(from: saturday), inSameDayAs: expected))
    }

    func testSundayWalksBackToThePrecedingWeeksMonday() {
        // 2026-08-02 is a Sunday — the last day of the week that started
        // Monday 2026-07-27, not the first day of the week starting 08-03.
        let sunday = date(year: 2026, month: 8, day: 2)
        let expected = date(year: 2026, month: 7, day: 27)
        XCTAssertTrue(cal.isDate(Formatters.nearestPastMonday(from: sunday), inSameDayAs: expected))
    }
}
