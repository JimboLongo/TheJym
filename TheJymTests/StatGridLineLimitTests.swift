//
//  StatGridLineLimitTests.swift
//  TheJymTests
//
//  Pins the one case that proves StatGridCell's .lineLimit(1) is doing
//  something, which no test at the shipping floor can show.
//
//  Given the choice, SwiftUI wraps rather than scales, so the line limit
//  is what makes minimumScaleFactor engage at all. Whether that is
//  VISIBLE depends on the floor: if scaling can fit the string in one
//  line, removing the limit changes the render; if it can't, both paths
//  end at the same truncated result. At the shipping floor of 0.52 a
//  sweep of 11 strings x 26 widths finds no difference at all — which
//  is why this test builds the real cell with a lower floor, in the
//  regime where the choice is live.
//
//  Sabotage check: delete .lineLimit(1) in StatGridCell and this fails.
//

import XCTest
import SwiftUI
@testable import TheJym

@MainActor
final class StatGridLineLimitTests: XCTestCase {

    /// Needs 0.4447 in a 256pt column at AX5 — inside a 0.44 floor, so
    /// scaling is a viable alternative to wrapping and the line limit
    /// decides which happens. (This was the real "MMMM yyyy" best-month
    /// value before it was abbreviated; it is kept as a test fixture
    /// precisely because it sits in that regime.)
    private let discriminating = "September 2026 (31)"

    func testTheLineLimitIsWhatMakesItScaleRatherThanWrap() throws {
        let roomy = try ink(width: 900, floor: 0.44)
        let cramped = try ink(width: 256, floor: 0.44)
        // Scaled to fit: much less ink, spanning nearly the full column.
        XCTAssertLessThan(Double(cramped.rows), Double(roomy.rows) * 0.6,
                          "at a 0.44 floor the value must scale to one line "
                          + "(ink \(cramped.rows) rows vs \(roomy.rows) roomy). Without "
                          + ".lineLimit(1) SwiftUI wraps at full size instead, which measured "
                          + "0.938 of the roomy ink.")
        XCTAssertGreaterThan(cramped.inkWidth, 240,
                             "scaled-to-fit ink spans \(cramped.inkWidth)pt of a 256pt column; "
                             + "a wrapped render only reached 210pt")
    }

    private func ink(width: CGFloat, floor: CGFloat) throws -> (rows: Int, inkWidth: Int) {
        let v = StatGridCell(minimumScale: floor, label: "", value: discriminating)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: width, alignment: .leading)
            .background(Color.white)
        let r = ImageRenderer(content: v)
        r.scale = 1
        guard let cg = r.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rows = 0, minX = Int.max, maxX = -1
        for y in 0..<h {
            var hit = false
            for x in 0..<w {
                let i = (y * w + x) * 4
                if px[i] < 200 || px[i + 1] < 200 || px[i + 2] < 200 {
                    hit = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
            if hit { rows += 1 }
        }
        return (rows, maxX >= minX ? maxX - minX + 1 : 0)
    }
}
