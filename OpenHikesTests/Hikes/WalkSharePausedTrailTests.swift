//
//  WalkSharePausedTrailTests.swift
//  OpenHikesTests
//
//  A share card draws the ground that was walked (#1122). A pause, or a GPX
//  `<trkseg>` break, is not trail (see *The app* in AGENTS.md): the leg
//  across it is a drive, a lift or a jump between two files' worth of
//  walking, and the phone's map, the widget and the watch all leave it
//  undrawn as solid line. The card's route box drew the trail as one line,
//  so its outline ran straight across the transfer.
//
//  The trail here is two walks up the west and east edges of a square, the
//  second resumed in the south-east corner: the transfer is the diagonal,
//  and the box's middle lies on it and on nothing else.
//

import CoreGraphics
import CoreLocation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import SwiftUI
import Testing

@MainActor
@Suite("Walk share route across a pause")
struct WalkSharePausedTrailTests {
    /// How the trail came to be in two pieces.
    enum Break: String, CaseIterable, Sendable {
        /// The hiker paused the recording and moved.
        case paused = "paused"
        /// The trail was imported from a file of two `<trkseg>`s.
        case segments = "segments"
    }

    private static let side = 0.02

    /// The two walks, as degrees `(latitude, longitude)`: up the west edge,
    /// then up the east one.
    private static let west = [(0.0, 0.0), (side / 2, 0.0), (side, 0.0)]
    private static let east = [(0.0, side), (side / 2, side), (side, side)]

    private static func route(_ cut: Break) -> [RouteCoordinate] {
        switch cut {
        case .paused:
            let before = west.map { RouteCoordinate(latitude: $0.0, longitude: $0.1) }
            let after = east.indices.map { index in
                RouteCoordinate(
                    latitude: east[index].0,
                    longitude: east[index].1,
                    boundary: index == 0 ? .paused : nil
                )
            }
            return before + after
        case .segments:
            func points(_ walk: [(Double, Double)]) -> [GPXImport.Point] {
                walk.map { latitude, longitude in
                    GPXImport.Point(
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        elevation: nil,
                        time: nil
                    )
                }
            }
            return GPXImport.Track.route(of: [points(west), points(east)])
        }
    }

    private static func shape(_ cut: Break, walked: Bool) async -> WalkShareRouteShape {
        let profile = RouteProfile(route: route(cut))
        return await WalkShareFlow.shape(of: [0...profile.totalDistanceMeters], along: profile, walked: walked)
    }

    /// The route box drawn on nothing, at one pixel a point.
    private static func rendered(_ shape: WalkShareRouteShape) throws -> CGImage {
        let renderer = ImageRenderer(content: WalkShareRouteBox(shape: shape, style: .bare, color: .white, metric: 1))
        renderer.scale = 1
        renderer.isOpaque = false
        return try #require(renderer.cgImage)
    }

    /// Where the unit square's `point` is drawn in a box rendered at a metric
    /// of 1: past the bare style's padding, and inset by twice the line.
    private static func drawn(_ point: CGPoint) -> CGPoint {
        let padding: CGFloat = 6
        let inset: CGFloat = 9
        let inner = WalkShareRouteBox.naturalSide - inset * 2
        return CGPoint(x: padding + inset + point.x * inner, y: padding + inset + point.y * inner)
    }

    @Test("no solid trail is drawn across the transfer", arguments: Break.allCases, [false, true])
    func transferIsNotDrawn(cut: Break, walked: Bool) async throws {
        let image = try Self.rendered(await Self.shape(cut, walked: walked))

        // The middle of the west walk is drawn, so the box drew a line …
        let onTrail = try #require(Self.alpha(in: image, at: Self.drawn(CGPoint(x: 0, y: 0.5))))
        #expect(onTrail > 200)
        // … and the middle of the diagonal, which only the transfer crosses,
        // is left as it was.
        let onTransfer = try #require(Self.alpha(in: image, at: Self.drawn(CGPoint(x: 0.5, y: 0.5))))
        #expect(onTransfer == 0, "the line across the \(cut.rawValue) transfer was drawn")
    }

    /// The two walks are two lines, up the box's two edges, and what was
    /// covered is drawn in the same frame, on them.
    @Test("each walk is its own line, and the covered stretches land on them", arguments: Break.allCases)
    func runsShareOneFrame(cut: Break) async throws {
        let shape = await Self.shape(cut, walked: true)

        try #require(shape.trail.count == 2)
        #expect(shape.trail[0].allSatisfy { $0.x.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6) })
        #expect(shape.trail[1].allSatisfy { $0.x.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-6) })
        // Both walk north, from the bottom edge to the top.
        #expect(shape.trail.allSatisfy { line in
            line.first?.y.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-6) == true
                && line.last?.y.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6) == true
        })

        try #require(shape.walked.count == 2)
        #expect(shape.walked[0].allSatisfy { $0.x.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6) })
        #expect(shape.walked[1].allSatisfy { $0.x.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-6) })
    }

    /// A fix with a pause on both sides is a place, not a line, so it is
    /// neither drawn nor allowed to shrink the drawing to make room for it.
    @Test("a lone fix between two pauses is not drawn or fitted")
    func loneFixIsLeftOut() throws {
        var trail = Self.route(.paused)
        // A fix far to the east, between the two walks.
        trail.insert(RouteCoordinate(latitude: Self.side / 2, longitude: 1, boundary: .paused), at: Self.west.count)
        let shape = WalkShareRouteShape(fitting: trail.map(\.clCoordinate), walked: [], cutAt: trail.trailRuns)

        try #require(shape.trail.count == 2)
        #expect(shape.trail.joined().allSatisfy { $0.x <= 1 + 1e-6 })
        #expect(shape.trail[1].first?.x.isApproximatelyEqual(to: 1, absoluteTolerance: 1e-6) == true)
    }

    /// The alpha of the pixel at `point`, counted from the top left.
    private static func alpha(in image: CGImage, at point: CGPoint) -> Int? {
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
                    x: -point.x.rounded(.down),
                    y: -(CGFloat(image.height) - 1 - point.y.rounded(.down)),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        return drawn ? Int(pixel[3]) : nil
    }
}
