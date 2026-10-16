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
    private static let deviceColumns: [CGFloat] = [120.0, 147.5, 155.0, 156.5, 161.0, 175.0, 180.0]
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
        ("Perfect Cycles", "No completed cycles yet"),
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
        XCTAssertGreaterThan(unpinnedHeight("No completed cycles yet", width: 161.0), oneLine,
                             "Perfect Cycles' empty-state value wraps unpinned (38.0 vs \(oneLine))")
        XCTAssertGreaterThan(unpinnedHeight("September 2026 (31)", width: 161.0), oneLine,
                             "the longest bestMonthLabel wraps unpinned (38.0 vs \(oneLine))")
        // And the near-miss that makes this a "hasn't happened yet":
        // 147.333 intrinsic against a 147.5 column on a 375pt phone.
        XCTAssertEqual(unpinnedHeight("100% (on pace)", width: 147.5), oneLine,
                       accuracy: 0.5, "fits by 0.167pt at xLarge on a 375pt phone — see StatGridCell")
    }
}
