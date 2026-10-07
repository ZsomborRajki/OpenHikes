//
//  WalkSharePhotoFrameTests.swift
//  OpenHikesTests
//
//  The share card never shows anything but photograph: no zoom below filling
//  it, and no pan that brings an edge of the picture inside the card.
//

import CoreGraphics
@testable import OpenHikes
import RealModule
import Testing

@Suite("Walk share photo frame")
struct WalkSharePhotoFrameTests {
    /// A landscape photograph on a portrait card: it fills the height, and
    /// overhangs the sides.
    private static let photo = CGSize(width: 4000, height: 3000)
    private static let canvas = CGSize(width: 400, height: 800)

    @Test("at zoom 1 the photograph fills the card's longer need exactly")
    func fillsTheCard() {
        let drawn = WalkSharePhotoFrame().drawnSize(of: Self.photo, on: Self.canvas)

        #expect(drawn.height.isApproximatelyEqual(to: 800, absoluteTolerance: 1e-9))
        #expect(drawn.width > Self.canvas.width)
    }

    @Test("zoom is kept between filling the card and four times that")
    func clampsTheZoom() {
        let small = WalkSharePhotoFrame(zoom: 0.2).clamped(image: Self.photo, canvas: Self.canvas)
        let huge = WalkSharePhotoFrame(zoom: 40).clamped(image: Self.photo, canvas: Self.canvas)

        #expect(small.zoom == 1)
        #expect(huge.zoom == WalkSharePhotoFrame.zoomRange.upperBound)
    }

    @Test("a pan stops where the photograph's edge meets the card's")
    func clampsThePan() {
        let frame = WalkSharePhotoFrame(offset: CGVector(dx: 5, dy: 5)).clamped(image: Self.photo, canvas: Self.canvas)
        let drawn = frame.drawnSize(of: Self.photo, on: Self.canvas)
        let slack = (drawn.width - Self.canvas.width) / 2 / Self.canvas.width

        #expect(frame.offset.dx.isApproximatelyEqual(to: slack, absoluteTolerance: 1e-9))
        // Filled exactly top to bottom, so there is no room to move that way.
        #expect(frame.offset.dy == 0)
    }
}
