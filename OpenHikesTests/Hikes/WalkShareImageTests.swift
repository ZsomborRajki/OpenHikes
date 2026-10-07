//
//  WalkShareImageTests.swift
//  OpenHikesTests
//
//  The exported share card: the editor's canvas drawn at the editor's size
//  and a larger pixel scale, so it comes out a fixed width in pixels and the
//  editor's shape — the screen's, not a preset.
//

import CoreGraphics
import ImageIO
@testable import OpenHikes
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers

@Suite("Walk share image")
struct WalkShareImageTests {
    private static func card() -> WalkShareCard {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        return WalkShareCard(
            photo: photo,
            figures: WalkShareFigures(
                title: "Ridge Loop",
                walkedMeters: 5000,
                activeSeconds: 3600,
                ascentMeters: 420,
                descentMeters: 400,
                completion: 1,
                startedAt: Date(timeIntervalSince1970: 1_750_000_000)
            ),
            shape: WalkShareRouteShape(trail: [.zero, CGPoint(x: 1, y: 1)], walked: []),
            tint: .green
        )
    }

    @Test("the card is a JPEG the export's width, in the editor's shape")
    func rendersAtTheExportWidth() throws {
        let canvas = CGSize(width: 402, height: 874)
        let image = WalkShareImage(
            card: Self.card(),
            layout: .standard,
            photoFrame: WalkSharePhotoFrame(),
            canvas: canvas
        )
        let data = try #require(image.render())
        // Kept in the result bundle, so the picture a change draws can be
        // looked at rather than only measured.
        Attachment.record(data, named: "walk-share-card.jpeg")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(width == Int(WalkShareImage.pixelWidth))
        #expect(abs(Double(height) - Double(width) * canvas.height / canvas.width) <= 1)
    }

    @Test("a card with no size yet has nothing to draw")
    func noSizeNoImage() {
        let image = WalkShareImage(
            card: Self.card(),
            layout: .standard,
            photoFrame: WalkSharePhotoFrame(),
            canvas: .zero
        )

        #expect(image.render() == nil)
    }
}
