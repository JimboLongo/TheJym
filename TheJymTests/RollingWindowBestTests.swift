//
//  RollingWindowBestTests.swift
//  TheJymTests
//
//  The Rolling Averages table's Best column, and the width budget that
//  decided its shape.
//
//  THE WIDTH TEST IS THE POINT OF THIS FILE. Every cell in that Grid is
//  .fixedSize(), so a table that doesn't fit OVERFLOWS rather than
//  compressing — there is no per-column squeeze to spend, and the budget
//  is total-needed against total-available. A five-column version needs
//  434pt at spacing 12 against a 375pt device, which is why Best replaced
//  Rest instead of joining it. Nothing asserted that before, and the
//  comment that was supposed to document it cited 44.5pt for a font the
//  percent cell doesn't use. It measures 55.667pt.
//

import XCTest
import SwiftUI
@testable import TheJym

@MainActor
final class RollingWindowBestTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var anchor = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    private func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: anchor)! }

    private func width(_ text: String, font: Font) -> CGFloat {
        let v = Text(text).font(font).environment(\.dynamicTypeSize, .large)
        return UIHostingController(rootView: v)
            .sizeThatFits(in: CGSize(width: CGFloat(100_000), height: CGFloat(100_000))).width
    }

    // MARK: - The budget

    /// Re-derives the total from the real fonts rather than restating the
    /// comment's arithmetic, so a font change or a new column is caught
    /// here instead of on a 375pt phone.
    func testTheTableFitsTheNarrowestDevice() {
        let pct = width("100.0%", font: .system(.subheadline, design: .monospaced).bold())
        let label = width("365 days", font: .subheadline)
        let columns = RollingWindowTable.columnCount
        let spacing = RollingWindowTable.horizontalSpacing
        let total = label + CGFloat(columns) * pct + CGFloat(columns) * spacing + 32

        XCTAssertEqual(pct, 55.667, accuracy: 0.01,
                       "\"100.0%\" at .subheadline monospaced bold — if this moved, the budget "
                       + "below moved with it")
        XCTAssertLessThanOrEqual(total, 375,
                                 "The table needs \(total)pt and the narrowest supported device "
                                 + "is 375pt. Every cell is .fixedSize(), so this OVERFLOWS "
                                 + "rather than shrinking. \(columns) columns at spacing "
                                 + "\(spacing) does not fit — drop a column, shorten the widest "
                                 + "cell, or change the layout. Do not just reduce the spacing: "
                                 + "measured, 5 columns needs 434pt at 12 and still 394pt at 4.")
    }

    /// The specific thing the old comment got wrong, pinned: the percent
    /// cell is NOT .caption, and the difference is 11pt — more than the
    /// slack the four-column table has.
    func testThePercentCellIsNotCaptionSized() {
        let asRendered = width("100.0%", font: .system(.subheadline, design: .monospaced).bold())
        let asCaption = width("100.0%", font: .system(.caption, design: .monospaced))
        XCTAssertGreaterThan(asRendered - asCaption, 10,
                             "the old budget cited the .caption width (\(asCaption)pt) for a cell "
                             + "that renders at \(asRendered)pt")
    }

    func testRestIsNoLongerAColumnButIsStillDerivable() {
        XCTAssertFalse(RollingWindowTable.columns.contains("Rest"))
        XCTAssertEqual(RollingWindowTable.columns, ["Best", "Active", "Lift", "Walk"])
        let w = RollingWindow(days: 30, active: 25, lift: 18, walk: 7, bestActive: 30)
        XCTAssertEqual(w.rest, 5, "days - active, exactly")
        XCTAssertEqual(w.percent(for: "Active") + 100 * Double(w.rest) / 30, 100, accuracy: 1e-9,
                       "Rest is 100% - Active, which is why it carries nothing of its own")
    }

    // MARK: - The scan

    /// A window reaching back before the first active day is not
    /// eligible: it would be padded with days that could not have been
    /// logged, and would measure the length of the history rather than
    /// the training.
    func testWindowsReachingBeforeTheFirstActiveDayAreExcluded() {
        // 10 active days, all consecutive, ending 4 days ago.
        let days = Set((0...9).map { day(-13 + $0) })
        let best = StatsEngine.bestActiveCounts(activeDays: days, effectiveToday: day(0),
                                                lengths: [10, 30])
        XCTAssertEqual(best[0], 10, "a 10-day window fits exactly over the 10 logged days")
        XCTAssertEqual(best[1], 0,
                       "a 30-day window cannot start on or after the first active day and still "
                       + "end within the history, so there is no eligible window")
    }

    /// Best is a maximum over every eligible window, not the window
    /// ending today.
    func testBestFindsAnEarlierWindowThanTodays() {
        // A dense fortnight, then a sparse one.
        var days = Set((0...13).map { day(-27 + $0) })
        days.formUnion([day(-6), day(-2)])
        let best = StatsEngine.bestActiveCounts(activeDays: days, effectiveToday: day(0),
                                                lengths: [14])
        XCTAssertEqual(best[0], 14, "the dense fortnight, which is not the window ending today")
    }

    /// Best == Active is a real answer, not a bug to suppress: it means
    /// the window ending today IS the record. Two of the six windows read
    /// that way on the real store.
    func testBestEqualsActiveWhenTodaysWindowIsTheRecord() {
        let days = Set((0...29).map { day(-29 + $0) })
        let best = StatsEngine.bestActiveCounts(activeDays: days, effectiveToday: day(0),
                                                lengths: [30])
        XCTAssertEqual(best[0], 30)
    }

    func testNoActiveDaysGivesZeroNotACrash() {
        let best = StatsEngine.bestActiveCounts(activeDays: [], effectiveToday: day(0),
                                                lengths: [30, 365])
        XCTAssertEqual(best, [0, 0])
    }

    // MARK: - The cache

    /// Memoised because compute() runs ~215 times per render and the scan
    /// measured 0.51 ms. The cache must return the same answer, and must
    /// NOT return a stale one when the inputs change — the key is the
    /// whole input rather than a checksum for that reason.
    func testTheCacheReturnsFreshResultsWhenInputsChange() {
        let a = Set((0...29).map { day(-29 + $0) })
        let first = StatsEngine.bestActiveCounts(activeDays: a, effectiveToday: day(0),
                                                 lengths: [30])
        XCTAssertEqual(first[0], 30)
        XCTAssertEqual(StatsEngine.bestActiveCounts(activeDays: a, effectiveToday: day(0),
                                                    lengths: [30]), first, "same inputs, cached")

        // One day removed — a checksum-keyed cache is exactly where this
        // would hand back 30.
        var b = a
        b.remove(day(-15))
        XCTAssertEqual(StatsEngine.bestActiveCounts(activeDays: b, effectiveToday: day(0),
                                                    lengths: [30])[0], 29,
                       "a changed day set must not hit the cache")
        // A changed anchor, same days. Moving it FORWARD doesn't change
        // the answer — an eligible 30-day window still covers all 30
        // logged days, which is the right answer and not a cache hit.
        // Moving it BACK shortens the eligible history below the window
        // length, so the answer must change.
        XCTAssertEqual(StatsEngine.bestActiveCounts(activeDays: a, effectiveToday: day(5),
                                                    lengths: [30])[0], 30,
                       "a later anchor still admits the window covering every logged day")
        XCTAssertEqual(StatsEngine.bestActiveCounts(activeDays: a, effectiveToday: day(-15),
                                                    lengths: [30])[0], 0,
                       "an earlier anchor leaves only 15 days of history — no eligible 30-day "
                       + "window, and a stale cache would still say 30")
        // And a changed length list.
        XCTAssertEqual(StatsEngine.bestActiveCounts(activeDays: a, effectiveToday: day(0),
                                                    lengths: [30, 60]).count, 2)
    }
}
