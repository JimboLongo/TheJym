//
//  BodyWeightDayTests.swift
//  TheJymTests
//
//  Weigh-ins record to the day they're taken rather than snapping to the
//  week's Monday. Two rules fall out of that, and they are deliberately
//  NOT the same rule:
//
//    upsert   — one entry per CALENDAR DAY (BodyWeightEntry.entry(on:in:))
//    reminder — satisfied by ANY entry in the Mon-Sun week
//               (BodyWeightEntry.loggedInWeek(of:in:))
//
//  Existing entries are all Monday-dated and stay put; nothing reads them
//  back assuming that, which resolved(asOf:) is covered for here too.
//

import XCTest
import SwiftData
@testable import TheJym

final class BodyWeightDayTests: XCTestCase {
    private let cal = Calendar.current

    @MainActor
    private func makeContext() -> ModelContext {
        let container = try! ModelContainer(
            for: BodyWeightEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A known Monday, so "non-Monday" cases are unambiguous.
    private var monday: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 5))! }
    private func plus(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: monday)! }

    /// Mirrors the views' logWeight(): update the day's entry if there is
    /// one, otherwise insert.
    @MainActor
    private func log(_ weight: Double, on day: Date, into entries: inout [BodyWeightEntry]) {
        if let existing = BodyWeightEntry.entry(on: day, in: entries) {
            existing.weight = weight
        } else {
            entries.append(BodyWeightEntry(date: day, weight: weight))
        }
    }

    // MARK: - Any-day logging

    @MainActor
    func testLoggingOnANonMondayStoresThatDate() {
        var entries: [BodyWeightEntry] = []
        let wednesday = plus(2)
        log(181.4, on: wednesday, into: &entries)

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(cal.isDate(entries[0].date, inSameDayAs: wednesday),
                      "the entry must keep Wednesday, not snap back to Monday")
        XCTAssertEqual(cal.component(.weekday, from: entries[0].date), 4, "Wednesday")
    }

    // MARK: - Upsert is per calendar day

    @MainActor
    func testTwoEntriesOnTheSameDayUpsert() {
        var entries: [BodyWeightEntry] = []
        let wednesday = plus(2)
        log(181.4, on: wednesday, into: &entries)
        log(180.2, on: wednesday, into: &entries)

        XCTAssertEqual(entries.count, 1, "same day must update, not append")
        XCTAssertEqual(entries[0].weight, 180.2)
    }

    /// The behaviour change: under the old Monday snap these two would
    /// have collapsed into one entry.
    @MainActor
    func testTwoDifferentDaysInOneWeekBothPersist() {
        var entries: [BodyWeightEntry] = []
        log(181.4, on: plus(1), into: &entries)   // Tuesday
        log(180.2, on: plus(4), into: &entries)   // Friday

        XCTAssertEqual(entries.count, 2, "different days in one week are separate entries")
        XCTAssertEqual(Set(entries.map(\.weight)), [181.4, 180.2])
    }

    @MainActor
    func testTimeOfDayDoesNotSplitADay() {
        var entries: [BodyWeightEntry] = []
        let morning = cal.date(byAdding: .hour, value: 7, to: plus(2))!
        let evening = cal.date(byAdding: .hour, value: 21, to: plus(2))!
        log(181.4, on: morning, into: &entries)
        log(180.2, on: evening, into: &entries)

        XCTAssertEqual(entries.count, 1, "same calendar day regardless of time")
    }

    // MARK: - The reminder is weekly, not per-day

    @MainActor
    func testReminderIsSatisfiedByAMidWeekEntry() {
        let context = makeContext()
        let wednesday = BodyWeightEntry(date: plus(2), weight: 181.4)
        context.insert(wednesday)

        XCTAssertTrue(BodyWeightEntry.loggedInWeek(of: plus(2), in: [wednesday]),
                      "a Wednesday weigh-in satisfies that week")
        XCTAssertTrue(BodyWeightEntry.loggedInWeek(of: monday, in: [wednesday]),
                      "...asked from Monday too — it's the week that matters")
        XCTAssertTrue(BodyWeightEntry.loggedInWeek(of: plus(6), in: [wednesday]),
                      "...and from Sunday, the last day of the same week")
    }

    @MainActor
    func testReminderIsNotSatisfiedByAnAdjacentWeek() {
        let lastWeek = BodyWeightEntry(date: plus(-1), weight: 181.4)   // Sunday before
        let nextWeek = BodyWeightEntry(date: plus(7), weight: 181.4)    // following Monday
        XCTAssertFalse(BodyWeightEntry.loggedInWeek(of: monday, in: [lastWeek]),
                       "the Sunday before is the previous week")
        XCTAssertFalse(BodyWeightEntry.loggedInWeek(of: monday, in: [nextWeek]),
                       "the following Monday is the next week")
        XCTAssertFalse(BodyWeightEntry.loggedInWeek(of: monday, in: []))
    }

    @MainActor
    func testWeekBoundariesAreMondayThroughSunday() {
        let mon = BodyWeightEntry(date: monday, weight: 1)
        let sun = BodyWeightEntry(date: plus(6), weight: 2)
        for probe in 0...6 {
            XCTAssertTrue(BodyWeightEntry.loggedInWeek(of: plus(probe), in: [mon]),
                          "Monday's entry covers day offset \(probe)")
            XCTAssertTrue(BodyWeightEntry.loggedInWeek(of: plus(probe), in: [sun]),
                          "Sunday's entry covers day offset \(probe)")
        }
    }

    // MARK: - Reading entries back

    /// Nothing assumes Monday alignment on read: resolution is "most
    /// recent on or before", so denser entries make it more precise, not
    /// broken. Entries must be date-ascending, which every @Query site
    /// sorts by.
    @MainActor
    func testResolutionPicksTheMostRecentEntryOnOrBeforeADate() {
        let entries = [BodyWeightEntry(date: monday, weight: 185),
                       BodyWeightEntry(date: plus(2), weight: 183),
                       BodyWeightEntry(date: plus(4), weight: 181)]

        XCTAssertEqual(BodyWeightEntry.resolved(asOf: monday, in: entries), 185)
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(1), in: entries), 185,
                       "Tuesday still resolves to Monday's entry")
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(2), in: entries), 183,
                       "a mid-week entry takes effect on its own day")
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(3), in: entries), 183)
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(30), in: entries), 181)
        XCTAssertNil(BodyWeightEntry.resolved(asOf: plus(-1), in: entries),
                     "nothing on record yet")
    }

    /// The old data shape — every entry on a Monday — keeps resolving
    /// exactly as it did. No migration, nothing to reconcile.
    @MainActor
    func testMondayOnlyHistoryStillResolvesUnchanged() {
        let entries = (0..<4).map { BodyWeightEntry(date: plus($0 * 7), weight: 190 - Double($0)) }
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(3), in: entries), 190)
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(7), in: entries), 189)
        XCTAssertEqual(BodyWeightEntry.resolved(asOf: plus(13), in: entries), 189)
    }
}
