//
//  StatGridFloorTests.swift
//  TheJymTests
//
//  StatGridCell.defaultMinimumScale is 0.52, and 0.52 is not a design
//  decision — it is 256 / 484.667, a number computed by hand on the day
//  it was written from the strings the grid produced that day. Add a
//  stat, reword a label, change the adherence format, and the floor
//  silently stops reaching far enough: the height tests still pass, the
//  ink test still passes, and the cell quietly truncates.
//
//  So this file RE-DERIVES the number rather than restating it. A test
//  that hardcoded 0.52 on both sides would be checking the constant
//  against a copy of its own assumptions — the same nothing a diff over
//  two empty tier sets reports as perfect fidelity.
//
//  Derivation, all from production code, none of it retyped here:
//    - labels   StatGridLabel.allCases
//    - literals StatGridValueLiteral.allCases
//    - formatted values  StatsView.adherenceLabel / .milesLabel /
//                        .hoursLabel, and TrainingStats.monthLabel,
//                        called with the widest inputs each can take
//    - fonts    StatGridCell.labelFont / .valueFont
//
//  Add a longer string to any of those and this test fails, naming it.
//

import XCTest
import SwiftUI
@testable import TheJym

@MainActor
final class StatGridFloorTests: XCTestCase {

    /// The narrowest container this app can be handed: an iPad Slide
    /// Over at compact width, which gives statGrid's accessibility
    /// single-column fallback 256pt. Measured by hosting the real
    /// StatsView, not derived — the two widest phones don't follow the
    /// obvious formula either (see StatGridCell's own table).
    private static let narrowestColumn: CGFloat = 256

    /// Worst case: the largest accessibility size, where the single
    /// column applies and the type is biggest.
    private static let worstSize: DynamicTypeSize = .accessibility5

    /// Every value the four callers can render, built by calling the
    /// real formatters with the widest inputs they can be given.
    private func derivedValues() -> [String] {
        var out = StatGridValueLiteral.allCases.map(\.rawValue)

        // adherenceLabel: percent is filledSlots/daysElapsed*100, so it
        // is unbounded upward early in a phase; delta is a day count.
        // Widest realistic shape is a 4-digit percent with a 2-digit
        // delta and the longest of the three suffixes.
        for pct in [100.0, 96.0, 104.0, 1200.0] {
            for delta in [0, 2, -4, 11, -11] {
                out.append(StatsView.adherenceLabel(percent: pct, delta: delta))
            }
        }
        // milesLabel / hoursLabel, at lifetime magnitudes.
        for d in [0.0, 123.4, 1234.5, 12345.6] {
            out.append(StatsView.milesLabel(d))
            out.append(StatsView.hoursLabel(d))
        }
        // "x of y" cycle counts, both callers.
        for (a, b) in [(0, 0), (7, 7), (99, 99), (999, 999)] {
            out.append("\(a) of \(b)")
        }
        // Plain integer counts.
        out.append(contentsOf: ["0", "999", "9999", "99999"])
        // Rest bank, one decimal.
        out.append(String(format: "%.1f", 123.5))
        // Best month: every month name through the real formatter, with
        // the widest workout count a month can carry.
        var comps = DateComponents(year: 2026, day: 1)
        for month in 1...12 {
            comps.month = month
            if let date = Calendar.current.date(from: comps) {
                out.append("\(TrainingStats.monthLabel(date)) (31)")
            }
        }
        return out
    }

    private func intrinsicWidth(_ text: String, font: Font) -> CGFloat {
        let v = Text(text).font(font).environment(\.dynamicTypeSize, Self.worstSize)
        return UIHostingController(rootView: v)
            .sizeThatFits(in: CGSize(width: CGFloat(100_000), height: CGFloat(100_000))).width
    }

    func testFloorStillReachesTheWidestStringTheGridCanProduce() {
        var tightest: (scale: CGFloat, text: String, kind: String) = (1, "", "")
        for text in StatGridLabel.allCases.map(\.rawValue) {
            let needed = Self.narrowestColumn / intrinsicWidth(text, font: StatGridCell.labelFont)
            if needed < tightest.scale { tightest = (needed, text, "label") }
        }
        for text in derivedValues() {
            let needed = Self.narrowestColumn / intrinsicWidth(text, font: StatGridCell.valueFont)
            if needed < tightest.scale { tightest = (needed, text, "value") }
        }

        XCTAssertLessThanOrEqual(
            StatGridCell.defaultMinimumScale, tightest.scale,
            "The scale floor no longer reaches the widest string the grid can produce. "
            + "Tightest is the \(tightest.kind) <\(tightest.text)>, which needs "
            + String(format: "%.4f", tightest.scale)
            + " in a \(Self.narrowestColumn)pt column at \(Self.worstSize), but the floor is "
            + "\(StatGridCell.defaultMinimumScale). Either shorten that string or lower "
            + "StatGridCell.defaultMinimumScale to at most "
            + String(format: "%.2f", (tightest.scale * 100).rounded(.down) / 100) + ".")

        // The other direction, so the floor doesn't quietly drift miles
        // below what anything needs and stop meaning anything.
        XCTAssertGreaterThan(
            StatGridCell.defaultMinimumScale, tightest.scale - 0.02,
            "The floor is \(StatGridCell.defaultMinimumScale) but nothing needs below "
            + String(format: "%.4f", tightest.scale)
            + " — raise it so it still describes the real worst case.")
    }
}
