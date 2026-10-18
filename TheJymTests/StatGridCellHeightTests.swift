//
//  StatGridCellHeightTests.swift
//  TheJymTests
//
//  The clearance test for a self-sizing List row: is its height PINNED?
//
//  A row whose height changes with its width is what put
//  UpdateCoalescingCollectionView into a recursive layout loop on the Body
//  tab (commit 77ea2ff). statGrid is the same shape — a LazyVGrid of
//  multi-line-capable Text inside a self-sizing List row — and the only
//  thing standing between it and the same loop is StatGridCell's two
//  lineLimit(1)s.
//
//  Sabotage check: delete either lineLimit(1) in StatGridCell and
//  testHeightIsPinnedAcrossWidths fails on the real values below.
//

import XCTest
import SwiftUI
@testable import TheJym

@MainActor
final class StatGridCellHeightTests: XCTestCase {

    /// statGrid's column is `(deviceWidth - 80) / 2` — measured by hosting
    /// the real StatsView, not derived. These are every shipping iPhone
    /// width, each flanked by the ±1/3pt neighbours a collection view's
    /// rounded-vs-preferred width pass actually produces.
    private static let deviceColumns: [CGFloat] = [120.0, 147.5, 155.0, 156.5, 161.0, 171.0, 176.0]
    private static let columnWidths: [CGFloat] = {
        let third: CGFloat = 1.0 / 3.0
        var out: [CGFloat] = []
        for c in deviceColumns {
            out.append(c - third)
            out.append(c)
            out.append(c + third)
        }
        return out
    }()

    /// Every label and value the four statGrid callers can produce.
    /// currentPhaseSection, progressFallbackSection, milestonesSection,
    /// completedPhaseSection.
    private static let pairs: [(String, String)] = [
        ("Adherence", "100% (on pace)"),
        ("Adherence", "96% (4 behind)"),
        ("Adherence", "1200% (11 ahead)"),
        ("Perfect cycles", "No cycles yet"),
        ("Perfect cycles", "999 of 999"),
        ("Miles walked", "12345.6 mi"),
        ("Rest days banked", "12.5"),
        ("Lifetime perfect weeks", "999"),
        ("Current perfect-week streak", "999"),
        ("Perfect weeks", "999"),
        ("Perfect months", "999"),
        ("All-time miles", "12345.6 mi"),
        ("Best month all-time", "Sep 2026 (31)"),
        ("All-time active days", "9999"),
        ("All-time hours trained", "12345.6 hr"),
        ("Final adherence", "96% (4 behind)"),
        ("Perfect cycles", "999 of 999"),
    ]

    private func height(_ label: String, _ value: String,
                        width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let v = StatGridCell(label: label, value: value)
            .environment(\.dynamicTypeSize, size)
            .frame(width: width)
        return UIHostingController(rootView: v)
            .sizeThatFits(in: CGSize(width: width, height: CGFloat(100_000))).height
    }

    /// THE invariant. One height per Dynamic Type size, the same at every
    /// width — so no width wobble can flip the line count.
    func testHeightIsPinnedAcrossWidths() {
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5] {
            var expected: CGFloat?
            for (label, value) in Self.pairs {
                for width in Self.columnWidths {
                    let h = height(label, value, width: width, size: size)
                    if let expected {
                        XCTAssertEqual(h, expected, accuracy: 0.01,
                                       "\(size): <\(label)>/<\(value)> is \(h) at width \(width), "
                                       + "but \(expected) elsewhere — height must not vary with width")
                    } else {
                        expected = h
                    }
                }
            }
        }
    }

    /// At an accessibility size statGridColumns drops to ONE column, so
    /// the widths are different ones entirely — and that is exactly where
    /// minimumScaleFactor does its work. If scaling the glyphs down were
    /// to leave the line box at its unscaled height, or to change it, the
    /// variable height would be straight back.
    func testHeightIsPinnedAcrossAccessibilityWidths() {
        let third: CGFloat = 1.0 / 3.0
        var widths: [CGFloat] = []
        for c in [CGFloat(256), 311, 326, 329, 338, 354, 368] {
            widths.append(c - third); widths.append(c); widths.append(c + third)
        }
        let axSizes: [DynamicTypeSize] = [.accessibility1, .accessibility2,
                                          .accessibility3, .accessibility4, .accessibility5]
        for size in axSizes {
            var expected: CGFloat?
            for (label, value) in Self.pairs {
                for width in widths {
                    let h = height(label, value, width: width, size: size)
                    if let expected {
                        XCTAssertEqual(h, expected, accuracy: 0.01,
                                       "\(size): <\(label)>/<\(value)> is \(h) at width \(width), "
                                       + "but \(expected) elsewhere — scaled text must not move the height")
                    } else {
                        expected = h
                    }
                }
            }
        }
    }

    /// Proves minimumScaleFactor is actually doing something, which an
    /// equal-heights assertion cannot: a pinned height stays pinned
    /// whether the text scales or truncates.
    ///
    /// Same string, two widths. At a width that fits it, it renders at
    /// full size. At the narrowest accessibility column it cannot fit, so
    /// it must shrink — and shrunk glyphs leave a SHORTER ink trace.
    /// Without minimumScaleFactor it would truncate at full size instead
    /// and the two traces would match.
    ///
    /// Sabotage check: delete .minimumScaleFactor in StatGridCell and
    /// this fails (ink ratio 1.0 instead of 0.545).
    func testScaleFactorActuallyShrinksTheGlyphs() throws {
        // Widest real value: "1200% (11 ahead)", 484.667pt at AX5, which
        // is what sets StatGridCell.minimumScale.
        let value = "1200% (11 ahead)"
        let roomy = try inkHeight(value: value, width: 700, size: .accessibility5)
        let cramped = try inkHeight(value: value, width: 256, size: .accessibility5)
        XCTAssertGreaterThan(roomy, 0, "sanity: something was drawn")
        // Measured: 44px of ink roomy, 24px cramped — ratio 0.545, which
        // tracks the 0.5282 the width demands. The threshold is 0.75
        // because the one way of breaking this lands at 1.0: without
        // .minimumScaleFactor the glyphs stay full size and truncate.
        XCTAssertLessThan(Double(cramped), Double(roomy) * 0.75,
                          "at 256pt the value must SHRINK (ink \(cramped)px) rather than truncate "
                          + "or wrap at full size (ink \(roomy)px)")
        // Whether the floor is low enough for the widest string is NOT
        // asserted here: 484.667 would be a hardcoded copy of the number
        // the floor was derived from. StatGridFloorTests re-derives it
        // from the real labels, literals and formatters instead.
    }

    private func inkHeight(value: String, width: CGFloat, size: DynamicTypeSize) throws -> Int {
        try inkBounds(value: value, width: width, size: size).rows
    }

    /// Inked pixel rows, and the horizontal extent of the ink, for a cell
    /// rendered with an empty label so only the value draws.
    private func inkBounds(value: String, width: CGFloat,
                           size: DynamicTypeSize) throws -> (rows: Int, inkWidth: Int) {
        let v = StatGridCell(label: "", value: value)
            .environment(\.dynamicTypeSize, size)
            .frame(width: width, alignment: .leading)
            .background(Color.white)
        let renderer = ImageRenderer(content: v)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rows = 0
        var minX = Int.max, maxX = -1
        for y in 0..<h {
            var inked = false
            for x in 0..<w {
                let i = (y * w + x) * 4
                // Anything meaningfully darker than the white ground.
                if pixels[i] < 200 || pixels[i + 1] < 200 || pixels[i + 2] < 200 {
                    inked = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
            if inked { rows += 1 }
        }
        return (rows, maxX >= minX ? maxX - minX + 1 : 0)
    }

    /// CHECK 1 — the overlay's proposed width.
    ///
    /// `.overlay` is proposed its PARENT's size, and the parent here is
    /// the sizing glyph. If `.frame(maxWidth: .infinity)` were applied
    /// after the overlay instead of before it, the real text would be
    /// laying out against a one-character proposal — and every
    /// height-equality test in this file would still pass, because a
    /// collapsed width pins the height just as well as a correct one.
    ///
    /// So assert the ink actually spans the column.
    func testOverlayIsProposedTheFullColumnWidth() throws {
        // The widest real value. Comfortably within one line here, so it
        // is laid out rather than scaled: intrinsic 148.667pt in 338pt.
        let b = try inkBounds(value: "1200% (11 ahead)", width: 338, size: .large)
        XCTAssertGreaterThan(b.inkWidth, 120,
                             "the value's ink spans \(b.inkWidth)pt of a 338pt column — if this is "
                             + "about one character wide, the overlay is being proposed the sizing "
                             + "glyph's width instead of the column's")
        // And in a column too narrow for it, it fills the column rather
        // than collapsing: scaled to fit, the ink still reaches across.
        let narrow = try inkBounds(value: "1200% (11 ahead)", width: 120, size: .large)
        XCTAssertGreaterThan(narrow.inkWidth, 95,
                             "scaled-to-fit ink spans \(narrow.inkWidth)pt of a 120pt column")
    }

    /// CHECK 2 — the sizing glyph's font.
    ///
    /// A sizer in the wrong font pins the row to a stable but WRONG
    /// height, and no height-equality test would notice. The anchor is
    /// the height the grid had before any of this: measured by hosting
    /// the real StatsView, an unwrapped statGrid cell was 32.333pt tall
    /// at the default Dynamic Type size. The sizing glyphs must still
    /// produce exactly that.
    func testRowHeightMatchesTheOriginalUnconstrainedLayout() {
        for (label, value) in Self.pairs {
            XCTAssertEqual(height(label, value, width: 161.0, size: .large), 32.333,
                           accuracy: 0.01,
                           "<\(label)>/<\(value)> is not the 32.333pt the grid measured before "
                           + "the sizing glyphs went in — is a sizer's font out of step with its text?")
        }
    }

    /// The other half of the sabotage check: these are not strings that
    /// happen to fit. Without the lineLimit they genuinely wrap at a real
    /// column width, which is what makes the test above meaningful rather
    /// than vacuous.
    func testTheseValuesReallyDoWrapUnpinned() {
        func unpinnedHeight(_ text: String, width: CGFloat) -> CGFloat {
            let v = Text(text)
                .font(.system(.subheadline, design: .monospaced)).bold()
                .environment(\.dynamicTypeSize, .large)
                .frame(width: width, alignment: .leading)
            return UIHostingController(rootView: v)
                .sizeThatFits(in: CGSize(width: width, height: CGFloat(100_000))).height
        }
        func unpinnedLabelHeight(_ text: String, width: CGFloat) -> CGFloat {
            let v = Text(text)
                .font(.caption2)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: width, alignment: .leading)
            return UIHostingController(rootView: v)
                .sizeThatFits(in: CGSize(width: width, height: CGFloat(100_000))).height
        }
        // Both of these clear their column by a third of a point or less
        // — which is exactly the width wobble a self-sizing row sees
        // between the collection view's two layout passes. Half a point
        // narrower and the line count flips.
        //
        // "100% (on pace)": 147.333pt intrinsic against a 375pt phone's
        // 147.5pt column. (Measured at xLarge; reproduced here at the
        // default size by using the width the ratio works out to.)
        let oneLine = unpinnedHeight("100% (on pace)", width: 161.0)
        XCTAssertEqual(unpinnedHeight("100% (on pace)", width: 130.0), oneLine,
                       accuracy: 0.5, "fits at its own intrinsic width of 130.0")
        XCTAssertGreaterThan(unpinnedHeight("100% (on pace)", width: 129.5), oneLine,
                             "and wraps half a point narrower")
        // "Lifetime perfect weeks": 119.667pt against a 320pt container's
        // 120.0pt column, at the DEFAULT type size.
        let oneLabelLine = unpinnedLabelHeight("Lifetime perfect weeks", width: 161.0)
        XCTAssertEqual(unpinnedLabelHeight("Lifetime perfect weeks", width: 120.0), oneLabelLine,
                       accuracy: 0.5, "clears a 320pt container's column by 0.333pt")
        XCTAssertGreaterThan(unpinnedLabelHeight("Lifetime perfect weeks", width: 118.0), oneLabelLine,
                             "and wraps just below it — see StatGridCell")
    }
}
