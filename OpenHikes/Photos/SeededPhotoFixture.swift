//
//  SeededPhotoFixture.swift
//  OpenHikes
//
//  Photos for a hike that no one photographed.
//
//  The gallery, the thumbnail decode and the viewer are the part of the app UI
//  automation cannot otherwise reach: the Simulator has no camera, and the
//  library picker is a system process a test is not allowed to drive. So every
//  scenario of the since-retired performance harness measured a hike with an
//  empty strip, and the photo pipeline shipped without appearing in a single
//  number.
//
//  This closes that hole from the app side, behind `--ui-test-seed-photos=N`.
//  What it fakes is the pixels and nothing else: the bytes go through
//  ``HikePhotoImport``, so they are written by the real ``HikePhotoStore``,
//  land as real files, and are read back by the real ImageIO decode path the
//  strip uses. A test that opens the detail screen afterwards is exercising
//  the shipping code.
//
//  The drawing matters more than it looks. A flat fill compresses to a few
//  kilobytes and decodes almost for free, which would produce a reassuring
//  measurement of nothing; the gradient and the scattered shapes below exist
//  to give the encoder something incompressible, so the file lands in the
//  megabytes a phone camera actually produces.
//

import CoreLocation
import Foundation

#if DEBUG
#if os(iOS)
import OpenHikesData
import UIKit
#endif

nonisolated enum SeededPhotoFixture {
    /// Matches a modern iPhone's 12 MP still, because the cost being measured
    /// is a decode and a decode is priced per pixel.
    private static let pixelWidth = 4032.0
    private static let pixelHeight = 3024.0
    private static let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
    private static let quality = 0.9
    private static let shapesPerImage = 60
    /// Distinct enough that eight tiles are visibly eight photos.
    private static let hueCount = 12
    private static let backgroundSaturation = 0.5
    private static let backgroundBrightness = 0.9
    private static let shapeSaturation = 0.8
    private static let shapeBrightness = 0.7
    private static let shapeOpacity = 0.5
    /// Shapes span up to a third of the frame, which is what gives the encoder
    /// detail at every scale instead of a few large flat areas.
    private static let shapeExtent = 3.0
    private static let goldenOffset: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let randomMultiplier: UInt64 = 6_364_136_223_846_793_005
    private static let randomIncrement: UInt64 = 1_442_695_040_888_963_407
    private static let randomMask: UInt64 = 0xFFFF

    /// Attaches `count` generated photos to `hike`, spaced along its route.
    ///
    /// Spaced rather than piled on one coordinate so the anchored/unanchored
    /// split the strip's footnote describes is exercised too, and so the
    /// viewer has somewhere different to point for each one.
    @MainActor
    static func attach(
        count: Int,
        to hike: Hike,
        store: HikePhotoStore = .shared
    ) async {
        guard count > 0 else { return }
        let coordinates = anchors(count: count, along: hike.route)
        for index in 0..<count {
            guard let data = await encodedImage(index: index) else { continue }
            await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: coordinates[index],
                savesToPhotoLibrary: false,
                store: store
            )
        }
    }

    /// Evenly spaced points along the route, or `nil`s when there is no route
    /// to pin to — which is itself a case the gallery has to draw.
    private static func anchors(
        count: Int,
        along route: [RouteCoordinate]
    ) -> [CLLocationCoordinate2D?] {
        guard !route.isEmpty else {
            return Array(repeating: nil, count: count)
        }
        return (0..<count).map { index in
            let position = route.count * index / count
            let point = route[min(position, route.count - 1)]
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
    }

    /// JPEG bytes at `size`, drawn off the main thread because a 12 MP render
    /// and encode is exactly the kind of work the rest of this app refuses to
    /// do on it.
    ///
    /// The size is a parameter and defaults to a phone camera's, which is the
    /// only thing this fixture was originally for: a decode is priced per
    /// pixel, so a performance scenario measuring the gallery has to be
    /// measuring a real one.
    ///
    /// ``SeededCommunityTransport`` is the caller that wants a smaller one. It
    /// encodes these every time a preview opens rather than once per scenario,
    /// and what a functional test needs from a photograph is that it is a real
    /// file the real decode path can read — so it pays for a real JPEG and not
    /// for twelve megapixels of it.
    @concurrent
    static func encodedImage(index: Int, size: CGSize = pixelSize) async -> Data? {
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            draw(index: index, in: context.cgContext, size: size)
        }
        return image.jpegData(compressionQuality: quality)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func draw(index: Int, in context: CGContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let hue = Double(index % hueCount) / Double(hueCount)
        context.setFillColor(
            UIColor(
                hue: hue,
                saturation: backgroundSaturation,
                brightness: backgroundBrightness,
                alpha: 1
            ).cgColor
        )
        context.fill(bounds)

        // Pseudo-random but reproducible: two runs of the same scenario should
        // encode identical bytes, or the file size becomes a variable nobody
        // can account for when a number moves.
        var seed = UInt64(index &+ 1) &* goldenOffset
        for shape in 0..<shapesPerImage {
            seed = seed &* randomMultiplier &+ randomIncrement
            let unit = { (shift: UInt64) in
                Double((seed >> shift) & randomMask) / Double(randomMask)
            }
            let rect = CGRect(
                x: unit(0) * bounds.width,
                y: unit(16) * bounds.height,
                width: unit(32) * bounds.width / shapeExtent,
                height: unit(48) * bounds.height / shapeExtent
            )
            context.setFillColor(
                UIColor(
                    hue: (hue + Double(shape) / Double(shapesPerImage))
                        .truncatingRemainder(dividingBy: 1),
                    saturation: shapeSaturation,
                    brightness: shapeBrightness,
                    alpha: shapeOpacity
                ).cgColor
            )
            context.fillEllipse(in: rect)
        }
    }
    #endif
}
#endif
