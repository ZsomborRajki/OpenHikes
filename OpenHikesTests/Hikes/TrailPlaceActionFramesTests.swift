//
//  TrailPlaceActionFramesTests.swift
//  OpenHikesTests
//
//  Actual button measurements decide the rows. Hold the caption cutoff and
//  the odd-count and unconstrained cases to the same rule as the layout.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Place action rows")
struct TrailPlaceActionFramesTests {
    @Test("two caption lines still fit in four columns")
    func twoLinesFit() {
        let frames = frames(count: 4, width: 344) { _ in [50, 51, 60, 66] }
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 80, height: 66),
            CGRect(x: 88, y: 0, width: 80, height: 66),
            CGRect(x: 176, y: 0, width: 80, height: 66),
            CGRect(x: 264, y: 0, width: 80, height: 66),
        ])
    }

    @Test("a caption beyond the cutoff moves whole buttons into two rows")
    func tallerCaptionUsesTwoRows() {
        let frames = frames(count: 4, width: 344) { width in
            width < 100 ? [67, 50, 50, 50] : [50, 60, 55, 50]
        }
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 168, height: 60),
            CGRect(x: 176, y: 0, width: 168, height: 60),
            CGRect(x: 0, y: 68, width: 168, height: 55),
            CGRect(x: 176, y: 68, width: 168, height: 55),
        ])
    }

    @Test("an odd count halves upward and keeps its last partial row")
    func oddCount() {
        let frames = frames(count: 3, width: 200) { width in width < 90 ? [80, 80, 80] : [50, 50, 50] }
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 96, height: 50),
            CGRect(x: 104, y: 0, width: 96, height: 50),
            CGRect(x: 0, y: 58, width: 96, height: 50),
        ])
    }

    @Test("one column accepts tall captions and never proposes a negative width")
    func narrowWidth() {
        let frames = frames(count: 2, width: -10) { width in
            #expect(width >= 0)
            return [100, 120]
        }
        #expect(frames == [CGRect(x: 0, y: 0, width: 0, height: 100), CGRect(x: 0, y: 108, width: 0, height: 120)])
    }

    @Test("empty content is not measured")
    func empty() {
        let frames = TrailPlaceActionFrames.frames(width: 300, ideal: [], captionLineHeight: 15) { _ in
            Issue.record("empty content must not be measured")
            return []
        }
        #expect(frames.isEmpty)
    }

    @Test("an unspecified or infinite proposal uses the ideal widths", arguments: [CGFloat?.none, .infinity])
    func unconstrained(width: CGFloat?) {
        let frames = frames(count: 2, width: width) { _ in [50, 50] }
        #expect(frames == [CGRect(x: 0, y: 0, width: 80, height: 50), CGRect(x: 88, y: 0, width: 80, height: 50)])
    }

    private func frames(count: Int, width: CGFloat?, heights: (CGFloat) -> [CGFloat]) -> [CGRect] {
        TrailPlaceActionFrames.frames(
            width: width, ideal: Array(repeating: CGSize(width: 80, height: 50), count: count), captionLineHeight: 15
        ) { width in heights(width).map { CGSize(width: width, height: $0) } }
    }
}
