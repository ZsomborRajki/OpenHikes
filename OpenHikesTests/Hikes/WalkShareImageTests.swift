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
import RealModule
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
        #expect(
            Double(height).isApproximatelyEqual(to: Double(width) * canvas.height / canvas.width, absoluteTolerance: 1)
        )
    }

    @Test("a box stored past the edge is drawn wholly on the card, as the editor draws it")
    func clampsAStaleBoxOntoTheCard() throws {
        let canvas = CGSize(width: 402, height: 874)
        // The route box, backed, with its centre on the left edge: 178
        // points square at this width, so drawn where it was stored it would
        // reach 89 points in, and pulled onto the card it reaches 178.
        var layout = WalkShareLayout.standard
        layout.route.center = CGPoint(x: 0, y: 0.5)
        layout.routeStyle = .card
        let data = try #require(WalkShareImage(
            card: Self.card(),
            layout: layout,
            photoFrame: WalkSharePhotoFrame(),
            canvas: canvas
        ).render())
        let image = try #require(UIImage(data: data)?.cgImage)
        let scale = CGFloat(image.width) / canvas.width
        // Clear of the route's diagonal, which crosses the box's middle.
        let inside = try #require(Self.green(in: image, at: CGPoint(x: 140 * scale, y: (437 - 40) * scale)))
        let photo = try #require(Self.green(in: image, at: CGPoint(x: 300 * scale, y: (437 - 40) * scale)))

        #expect(inside < photo - 40, "the box's dark backing reaches 140 points in, so it was moved onto the card")
    }

    /// The green channel of the pixel at `point`, the one the backing darkens
    /// most on a teal photograph.
    private static func green(in image: CGImage, at point: CGPoint) -> Int? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Core Graphics counts up from the bottom.
            context.draw(
                image,
                in: CGRect(
                    x: -point.x.rounded(),
                    y: -(CGFloat(image.height) - point.y.rounded()),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        return drawn ? Int(pixel[1]) : nil
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
