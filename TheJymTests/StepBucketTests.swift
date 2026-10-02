//
//  StepBucketTests.swift
//  TheJymTests
//
//  The Steps screen's grouping. The load-bearing property is that a bucket
//  the Since date cuts into averages over the days actually INSIDE the
//  window, not the calendar length of the period — otherwise a Since set
//  mid-week silently divides a partial week's total by 7 and reads as a
//  slump that never happened.
//
//  Also pins the week start to Monday, matching
//  Formatters.nearestPastMonday (what BodyWeightView/TodayView snap
//  weigh-ins to). Calendar's own .weekOfYear follows the locale's first
//  weekday — Sunday in the US — so a Sunday would land in a different week
//  on this screen than on the weight screen if that were used instead.
//

import XCTest
@testable import TheJym

final class StepBucketTests: XCTestCase {
    private let cal = Calendar.current

    /// Monday 2026-09-28 .. Sunday 2026-10-04, a full Monday-start week.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func counts(_ spec: [(Int, Int, Int, Double)]) -> [DayCount] {
        spec.map { DayCount(day: cal.startOfDay(for: day($0.0, $0.1, $0.2)), value: $0.3) }
    }

    // MARK: - Week start

    func testWeekStartsMondayNotLocaleDefault() {
        // Sun 2026-10-04 must group with the Mon 2026-09-28 week, not open
        // a new one. Under a Sunday-first locale calendar it would.
        let days = counts([(2026, 9, 28, 1000), (2026, 10, 4, 2000)])
        let weeks = StepBucket.buckets(from: days, scale: .week)
        XCTAssertEqual(weeks.count, 1, "Sunday belongs to the week that began Monday")
        XCTAssertEqual(weeks[0].total, 3000)
        XCTAssertEqual(weeks[0].label, "Sep 28 – Oct 4")
    }

    func testMondayOpensANewWeek() {
        // Sun 2026-10-04 and Mon 2026-10-05 are different weeks.
        let days = counts([(2026, 10, 4, 1000), (2026, 10, 5, 2000)])
        let weeks = StepBucket.buckets(from: days, scale: .week)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks.map(\.label), ["Oct 5 – Oct 11", "Sep 28 – Oct 4"],
                       "newest first")
    }

    // MARK: - Since, and partially included buckets

    func testSinceMidWeekAveragesOverIncludedDaysOnly() {
        // A full week, 1000 steps every day: Mon 9/28 .. Sun 10/4.
        let week = counts((28...30).map { (2026, 9, $0, 1000.0) }
                          + (1...4).map { (2026, 10, $0, 1000.0) })
        XCTAssertEqual(week.count, 7)

        // Unfiltered: 7 days, 7000 total, 1000/day.
        let whole = StepBucket.buckets(from: week, scale: .week)[0]
        XCTAssertEqual(whole.days, 7)
        XCTAssertEqual(whole.total, 7000)
        XCTAssertEqual(whole.dailyAverage, 1000, accuracy: 0.001)

        // Since Thursday 10/1 — four days remain inside the window.
        let visible = StepBucket.visible(week, since: day(2026, 10, 1))
        let partial = StepBucket.buckets(from: visible, scale: .week)[0]
        XCTAssertEqual(partial.days, 4, "must count only days on or after Since")
        XCTAssertEqual(partial.total, 4000)
        XCTAssertEqual(partial.dailyAverage, 1000, accuracy: 0.001,
                       "dividing by 7 here would read as 571/day — a slump that never happened")
        XCTAssertEqual(partial.label, "Sep 28 – Oct 4",
                       "label still shows the true span, so a partial week is visible as one")
    }

    func testSinceMidMonthAveragesOverIncludedDaysOnly() {
        let month = counts((1...10).map { (2026, 9, $0, 500.0) })
        let visible = StepBucket.visible(month, since: day(2026, 9, 6))
        let partial = StepBucket.buckets(from: visible, scale: .month)[0]
        XCTAssertEqual(partial.days, 5)
        XCTAssertEqual(partial.total, 2500)
        XCTAssertEqual(partial.dailyAverage, 500, accuracy: 0.001)
        XCTAssertEqual(partial.label, "September 2026")
    }

    func testSinceIsInclusiveOfItsOwnDay() {
        let days = counts([(2026, 10, 1, 100), (2026, 10, 2, 200)])
        let visible = StepBucket.visible(days, since: day(2026, 10, 1))
        XCTAssertEqual(visible.count, 2, "Since Oct 1 includes Oct 1")
    }

    func testNilSinceKeepsEverything() {
        let days = counts([(2017, 11, 1, 100), (2026, 10, 2, 200)])
        XCTAssertEqual(StepBucket.visible(days, since: nil).count, 2)
    }

    func testSinceLaterThanAllDataGivesNothing() {
        // Drives the "No steps in this range" state rather than an error.
        let days = counts([(2026, 9, 1, 100)])
        XCTAssertTrue(StepBucket.visible(days, since: day(2026, 10, 1)).isEmpty)
    }

    // MARK: - Day scale is unchanged

    func testDayScaleIsOneRowPerDayWithDaysOne() {
        let days = counts([(2026, 10, 1, 100), (2026, 10, 2, 200)])
        let rows = StepBucket.buckets(from: days, scale: .day)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.days), [1, 1])
        // A day's average IS its total — which is why the Day view shows a
        // single value rather than the three-column table.
        XCTAssertEqual(rows[0].dailyAverage, rows[0].total)
        XCTAssertEqual(rows.map(\.total), [200, 100], "newest first")
    }

    // MARK: - Month / year totals

    func testYearGroupsAndAverages() {
        let days = counts([(2025, 1, 1, 100), (2025, 6, 1, 300), (2026, 1, 1, 50)])
        let years = StepBucket.buckets(from: days, scale: .year)
        XCTAssertEqual(years.map(\.label), ["2026", "2025"])
        XCTAssertEqual(years[1].total, 400)
        XCTAssertEqual(years[1].days, 2, "days with DATA, not 365")
        XCTAssertEqual(years[1].dailyAverage, 200, accuracy: 0.001)
    }

    func testEmptyInputGivesNoBuckets() {
        for scale in StepScale.allCases {
            XCTAssertTrue(StepBucket.buckets(from: [], scale: scale).isEmpty)
        }
    }
}
