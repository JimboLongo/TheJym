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
        ("Perfect Cycles", "No cycles yet"),
        ("Perfect Cycles", "999 of 999"),
        ("Miles walked", "12345.6 mi"),
        ("Rest days banked", "12.5"),
        ("Lifetime perfect weeks", "999"),
        ("Current perfect-week streak", "999"),
        ("Perfect weeks", "999"),
        ("Perfect months", "999"),
        ("All-time miles", "12345.6 mi"),
        ("Best month all-time", "September 2026 (31)"),
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
    /// Sabotage check: delete either .minimumScaleFactor in StatGridCell
    /// and this fails.
    func testScaleFactorActuallyShrinksTheGlyphs() throws {
        // Widest real value: "September 2026 (31)", 575.667pt at AX5.
        let value = "September 2026 (31)"
        let roomy = try inkHeight(value: value, width: 700, size: .accessibility5)
        let cramped = try inkHeight(value: value, width: 256, size: .accessibility5)
        XCTAssertGreaterThan(roomy, 0, "sanity: something was drawn")
        // Measured: 48px of ink roomy, 22px cramped — ratio 0.458, which
        // tracks the 0.4447 the width demands. The threshold is 0.6
        // because the two ways of breaking this both land far above it:
        // dropping .minimumScaleFactor gives full-size truncated glyphs,
        // and dropping .lineLimit(1) stops the scale factor applying at
        // all (measured ratio 0.9375 — it wraps and clips instead).
        XCTAssertLessThan(Double(cramped), Double(roomy) * 0.6,
                          "at 256pt the value must SHRINK (ink \(cramped)px) rather than truncate "
                          + "or wrap at full size (ink \(roomy)px)")
        // And the floor is low enough to fit it, not just to shrink it.
        XCTAssertLessThanOrEqual(256.0 / 575.667, Double(StatGridCell.minimumScale) + 0.005,
                                 "the measured requirement at AX5/256pt is 0.4447; the floor must reach it")
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
        // Comfortably within one line at this width and size, so it is
        // laid out, not scaled: intrinsic 176.333pt against 338pt.
        let b = try inkBounds(value: "September 2026 (31)", width: 338, size: .large)
        XCTAssertGreaterThan(b.inkWidth, 150,
                             "the value's ink spans \(b.inkWidth)pt of a 338pt column — if this is "
                             + "about one character wide, the overlay is being proposed the sizing "
                             + "glyph's width instead of the column's")
        // And a value too wide for the column still fills it rather than
        // collapsing: scaled to fit, it should reach most of the width.
        let wide = try inkBounds(value: "September 2026 (31)", width: 161, size: .large)
        XCTAssertGreaterThan(wide.inkWidth, 130,
                             "scaled-to-fit ink spans \(wide.inkWidth)pt of a 161pt column")
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
        // 161.0 is the column width on a 402pt phone at the default size.
        let oneLine = unpinnedHeight("100% (on pace)", width: 161.0)
        XCTAssertGreaterThan(unpinnedHeight("September 2026 (31)", width: 161.0), oneLine,
                             "the longest bestMonthLabel wraps unpinned at this phone's column width")
        // The near-misses that make this a "hasn't happened yet". Each
        // fits by less than a third of a point, which is exactly the
        // width wobble a self-sizing row sees between layout passes.
        XCTAssertEqual(unpinnedHeight("100% (on pace)", width: 147.5), oneLine,
                       accuracy: 0.5, "fits by 0.167pt at xLarge on a 375pt phone — see StatGridCell")
        // 176.333 intrinsic against a 176.0 column: it MISSES by a third
        // of a point on a 440pt phone at the default size, and clears by
        // the same margin a third of a point wider. Either side of that
        // line is a line-count flip.
        XCTAssertGreaterThan(unpinnedHeight("September 2026 (31)", width: 176.0), oneLine,
                             "wraps at a 440pt phone's 176.0 column")
        XCTAssertEqual(unpinnedHeight("September 2026 (31)", width: 176.0 + 2.0 / 3.0), oneLine,
                       accuracy: 0.5, "and fits two thirds of a point wider — see StatGridCell")
    }
}
