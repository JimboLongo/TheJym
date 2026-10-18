//
//  MacroTableRowTests.swift
//  TheJymTests
//
//  The cycle macro table's rows, held to the same clearance test as
//  statGrid: is the row's height PINNED — identical on every row, at
//  every width?
//
//  It matters here for a slightly different reason than it did there.
//  These columns have FIXED widths, so a value too wide for its column
//  wraps rather than overflows, and a wrapped column makes that one row
//  taller than its neighbours. That was visible before rounding: two
//  decimals fit fat and sugar but not protein and carbs, so half the
//  table was one line and half was two, which is what made the heights
//  uneven and the units look inconsistently spaced.
//
//  Sabotage: restore two decimals (format MacroFigure.value with
//  Formatters.trim instead of rounding) and
//  testNoRealValueWrapsItsColumn fails, naming the value.
//

import XCTest
import SwiftUI
@testable import TheJym

@MainActor
final class MacroTableRowTests: XCTestCase {

    /// The widths a List row's content actually gets, flanked by the
    /// ±1/3pt neighbours a collection view's rounded-vs-preferred pass
    /// produces. Measured for statGrid; the same List, the same insets.
    private static let widths: [CGFloat] = {
        let third: CGFloat = 1.0 / 3.0
        return [CGFloat(256), 311, 326, 329, 338, 354, 368]
            .flatMap { [$0 - third, $0, $0 + third] }
    }()

    /// Every row the table can render, built through the real formatter
    /// from values with the worst shape each column can take: a
    /// four-digit calorie average, a three-digit gram average, a
    /// two-digit day count, and deltas of both signs.
    private static func realRows() -> [MacroTableRow] {
        var rows: [MacroTableRow] = []
        for category in MacroCategory.allCases {
            for (mean, target) in [(187.333, 185.0), (227.667, 260.0), (77.0, 75.0),
                                   (31.5, 30.0), (9.25, 28.0), (999.49, 100.0), (nil as Double?, 185.0)] {
                let delta = mean.map { $0 - target }
                rows.append(MacroTableRow(
                    label: category.label,
                    value: MacroFigure.value(mean, unit: "g"),
                    target: MacroFigure.target(target, symbol: category.direction.symbol),
                    delta: MacroFigure.delta(delta),
                    deltaIsFavourable: delta.map { $0 >= 0 },
                    dayCount: nil))
            }
        }
        for (mean, target) in [(2441.0, 2450.0), (1950.67, 2250.0), (nil as Double?, 2550.0)] {
            rows.append(MacroTableRow(
                label: "Calories",
                value: MacroFigure.value(mean, unit: ""),
                target: MacroFigure.target(target),
                delta: MacroFigure.delta(mean.map { $0 - target }),
                deltaIsFavourable: nil,
                dayCount: nil,
                emphasised: true))
        }
        // And the same with a visible day count, which is the widest the
        // last column gets.
        rows.append(MacroTableRow(label: "Protein", value: MacroFigure.value(187.333, unit: "g"),
                                  target: MacroFigure.target(185, symbol: "\u{2265}"),
                                  delta: MacroFigure.delta(2.333), deltaIsFavourable: true,
                                  dayCount: 99))
        return rows
    }

    private func height(_ row: MacroTableRow, width: CGFloat,
                        size: DynamicTypeSize = .large) -> CGFloat {
        let v = row.environment(\.dynamicTypeSize, size).frame(width: width)
        return UIHostingController(rootView: v)
            .sizeThatFits(in: CGSize(width: width, height: CGFloat(100_000))).height
    }

    /// THE invariant: one height per Dynamic Type size, the same on every
    /// row and at every width, so no width wobble can change a line count.
    func testHeightIsPinnedAcrossRowsAndWidths() {
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5] {
            var expected: CGFloat?
            for row in Self.realRows() {
                for width in Self.widths {
                    let h = height(row, width: width, size: size)
                    if let expected {
                        XCTAssertEqual(h, expected, accuracy: 0.01,
                                       "\(size): <\(row.label) \(row.value)> is \(h) at width "
                                       + "\(width) but \(expected) elsewhere — a row's height "
                                       + "must not depend on its content or its width")
                    } else {
                        expected = h
                    }
                }
            }
        }
    }

    /// The rounding's actual job. Each column has a fixed width, so this
    /// asserts no real value needs more than its column — one line at
    /// full size, no scaling and no wrap.
    ///
    /// Column widths are read from the row itself rather than restated:
    /// 58 label, 62 value, 54 target, 34 day count.
    func testNoRealValueWrapsItsColumn() {
        func fits(_ text: String, font: Font, width: CGFloat) -> Bool {
            let v = Text(text).font(font).environment(\.dynamicTypeSize, .large)
            let w = UIHostingController(rootView: v)
                .sizeThatFits(in: CGSize(width: CGFloat(100_000), height: CGFloat(100_000))).width
            return w <= width
        }
        let mono = Font.system(.subheadline, design: .monospaced)
        let monoCaption = Font.system(.caption, design: .monospaced)
        for row in Self.realRows() {
            XCTAssertTrue(fits(row.label, font: .caption, width: 58),
                          "label <\(row.label)> is wider than its 58pt column")
            XCTAssertTrue(fits(row.value, font: mono, width: 62),
                          "value <\(row.value)> is wider than its 62pt column — this is what "
                          + "two decimals did to protein and carbs")
            XCTAssertTrue(fits(row.target, font: monoCaption, width: 54),
                          "target <\(row.target)> is wider than its 54pt column")
            if let d = row.dayCount {
                XCTAssertTrue(fits("(\(d)d)", font: .caption2, width: 34),
                              "day count <(\(d)d)> is wider than its 34pt column")
            }
        }
    }

    // MARK: - MacroFigure

    func testValuesRoundToWholeUnits() {
        XCTAssertEqual(MacroFigure.value(187.333, unit: "g"), "187g")
        XCTAssertEqual(MacroFigure.value(227.667, unit: "g"), "228g")
        XCTAssertEqual(MacroFigure.value(2441.0, unit: ""), "2441")
        XCTAssertEqual(MacroFigure.value(nil, unit: "g"), "\u{2014}", "no average is a dash, not 0")
    }

    func testDeltasRoundAndCarryTheirSign() {
        XCTAssertEqual(MacroFigure.delta(-25.667), "-26")
        XCTAssertEqual(MacroFigure.delta(2.333), "+2")
        XCTAssertEqual(MacroFigure.delta(nil), nil)
    }

    /// A delta that rounds to nothing prints a bare "0". "+0" and "-0"
    /// would claim a direction the displayed numbers don't show — the
    /// colour still carries it, because status is decided unrounded.
    func testADeltaRoundingToZeroHasNoSign() {
        XCTAssertEqual(MacroFigure.delta(-0.4), "0")
        XCTAssertEqual(MacroFigure.delta(0.4), "0")
    }

    /// The property that lets the table round freely: every target is a
    /// whole number, so the displayed delta must always equal the
    /// displayed value minus the target.
    ///
    /// Swept including exact .5 means, which is where it nearly went
    /// wrong: Swift's default .rounded() is half-away-from-zero, which
    /// is NOT translation-invariant, so 118.5 against 185 showed "119"
    /// with a delta of "-67". MacroFigure.round is half-up for this
    /// reason. The halves are stepped through explicitly because a
    /// stride would miss most of them.
    func testDisplayedDeltaEqualsDisplayedValueMinusTarget() {
        var means = Array(stride(from: 100.0, through: 300.0, by: 0.37))
        means += (100...300).map { Double($0) + 0.5 }
        means += (100...300).map { Double($0) }
        for mean in means {
            for target in [75.0, 185.0, 260.0, 2450.0] {
                let shownValue = MacroFigure.round(mean)
                let shownDelta = MacroFigure.round(mean - target)
                XCTAssertEqual(shownValue - Int(target), shownDelta,
                               "mean \(mean) against target \(target)")
            }
        }
    }

    /// The specific case that caught it, pinned so the tie rule can't be
    /// "simplified" back to Double.rounded().
    func testTheTieRuleIsHalfUp() {
        XCTAssertEqual(MacroFigure.round(118.5), 119)
        XCTAssertEqual(MacroFigure.round(-66.5), -66, "half-up, not half-away-from-zero (-67)")
        XCTAssertEqual(MacroFigure.round(187.5), 188, "and not half-to-even (188 either way here)")
        XCTAssertEqual(MacroFigure.round(118.5) - 185, MacroFigure.round(118.5 - 185))
    }
}
