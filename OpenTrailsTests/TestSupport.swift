//
//  TestSupport.swift
//  OpenTrailsTests
//
//  Fixtures shared across the suites: a couple of real-shaped trails, a
//  minimal in-memory SwiftData stack, and helpers for the tile pipeline
//  (which is documented as "must not run on main" and asserts as much).
//

import CoreLocation
import Foundation
import OpenTrailsShared
import SwiftData
import Testing
@testable import OpenTrails

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum Fixture {
    /// A short out-and-back near Cupertino: ~1.4 km, climbs then descends,
    /// one point per minute. Small enough to reason about by hand, real
    /// enough that distances/gradients aren't degenerate.
    static let ridgeRoute: [RouteCoordinate] = {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let points: [(Double, Double, Double)] = [
            (37.3300, -122.0300, 100),
            (37.3320, -122.0300, 150),
            (37.3340, -122.0300, 220),
            (37.3360, -122.0300, 180),
            (37.3380, -122.0300, 260),
            (37.3400, -122.0300, 240)
        ]
        return points.enumerated().map { index, point in
            RouteCoordinate(
                latitude: point.0,
                longitude: point.1,
                elevation: point.2,
                timestamp: start.addingTimeInterval(Double(index) * 60)
            )
        }
    }()

    /// A closed loop whose finish comes back within a few metres of its
    /// start — the geometry that makes route-matching ambiguous, and the
    /// reason `RouteProfile.nearestPoint` takes a continuity reference.
    static let loopRoute: [RouteCoordinate] = {
        let center = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        let radius = 0.0045 // ~500 m
        var points = (0..<36).map { step -> RouteCoordinate in
            let angle = Double(step) / 36 * 2 * .pi
            return RouteCoordinate(
                latitude: center.latitude + radius * cos(angle),
                longitude: center.longitude + radius * sin(angle) / cos(center.latitude * .pi / 180),
                elevation: 600 + 40 * sin(angle * 2)
            )
        }
        points.append(points[0]) // close the loop
        return points
    }()

    /// A trail that walks out to a turning point and comes back along the same
    /// path — the shape that had auto-follow start a hike at its finish.
    ///
    /// The return leg is offset by well under a metre, the way a receiver's
    /// second pass over the same ground really is: near enough that both legs
    /// are the same trail, unequal enough that the segment *closest* to a fix
    /// at the trailhead is decided by sampling noise rather than by where the
    /// walker is standing. An exactly mirrored fixture would hide the bug —
    /// with two identical candidates the earlier one wins by iteration order
    /// alone, which is the coin landing the right way up, not a tie being
    /// broken.
    static let outAndBackRoute: [RouteCoordinate] = {
        // ~0.75 m east at this latitude.
        let returnLegOffset = 1e-5
        let outbound = (0..<20).map { step in
            RouteCoordinate(
                latitude: 47.6300 + Double(step) * 0.0005, // ~56 m per step
                longitude: 12.8600,
                elevation: 600 + Double(step) * 8
            )
        }
        // Back down the same path. The turning point isn't repeated.
        let returning = outbound.dropLast().reversed().map { point in
            RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude + returnLegOffset,
                elevation: point.elevation
            )
        }
        return outbound + returning
    }()

    /// A ~10 km walk in Fiji that steps across ±180°. Short on the ground, but
    /// the widest possible span if longitude is read as a plain `min`/`max`
    /// interval — which is the mistake both the bulk downloader and the
    /// auto-save corridor have to avoid, so they're both tested against this
    /// same trail.
    static let antimeridianRoute: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: -17.70, longitude: 179.95),
        CLLocationCoordinate2D(latitude: -17.71, longitude: -179.95)
    ]

    /// The route as the map/downloader see it.
    static func coordinates(_ route: [RouteCoordinate]) -> [CLLocationCoordinate2D] {
        route.map(\.clCoordinate)
    }

    /// A hike backed by an in-memory store, so `@Model` bookkeeping
    /// (`autoSavedTileKeys`, `offlineDownloads`) behaves as it does in the app.
    @MainActor
    static func hike(
        title: String = "Ridge Loop",
        route: [RouteCoordinate] = ridgeRoute,
        in context: ModelContext,
        configure: (Hike) -> Void = { _ in }
    ) -> Hike {
        let profile = RouteProfile(route: route)
        let hike = Hike(
            title: title,
            distanceMeters: profile.distances.last ?? 0,
            route: route
        )
        configure(hike)
        context.insert(hike)
        return hike
    }

    @MainActor
    static func modelContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Hike.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    static func modelContext() throws -> ModelContext {
        ModelContext(try modelContainer())
    }

    /// A 1×1 tile image that really encodes — what the tile pipeline is
    /// handed in production, minus the 256×256.
    /// A tile at the size providers actually serve, for the questions where
    /// 1×1 gives the wrong answer — chiefly what a decoded tile costs in
    /// memory, where the whole point is that it dwarfs the compressed file.
    static func fullSizeTileImage(scale: CGFloat = 2) -> TileImage? {
        let points = 256.0
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: points, height: points), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: points, height: points))
        }
        #elseif canImport(AppKit)
        let pixels = Int(points * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        let image = NSImage(size: CGSize(width: points, height: points))
        image.addRepresentation(rep)
        return image
        #else
        return nil
        #endif
    }

    static func tileImage() -> TileImage? {
        let size = CGSize(width: 1, height: 1)
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
        #else
        return nil
        #endif
    }
}

/// Stands in for the tile pipeline's two on-disk tiers.
///
/// `TileCache` keeps both the directories and the key→filename mapping
/// private, so they're restated here; a change to either belongs in this type
/// too. Reaching in is the point: auto-save no longer takes an image and
/// encodes it, it moves the bytes a fetch already cached, so a test that wants
/// a tile to be savable has to put those bytes where a fetch would have.
enum TileStore {
    /// A real, decodable tile as bytes — what a fetch actually writes. Tests
    /// read tiles back through `TileCache`, so filler bytes wouldn't do.
    static let tileData: Data = {
        guard let image = Fixture.tileImage() else { return Data() }
        #if canImport(UIKit)
        return image.pngData() ?? Data()
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Data() }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) ?? Data()
        #else
        return Data()
        #endif
    }()

    static var tileByteCount: Int64 { Int64(tileData.count) }

    private static func file(for key: String, in directory: URL) -> URL {
        let name = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
        return directory.appendingPathComponent(name)
    }

    /// `Caches/OSMTiles` — where a tile fetched to draw the map lands, whether
    /// or not any hike will ever claim it.
    static func browsedFile(for key: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return file(for: key, in: caches.appendingPathComponent("OSMTiles", isDirectory: true))
    }

    /// `Application Support/OSMTilesSaved` — where a tile kept for offline use
    /// lands, out of reach of the OS reclaiming storage.
    static func savedFile(for key: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return file(for: key, in: support.appendingPathComponent("OSMTilesSaved", isDirectory: true))
    }

    /// Puts a tile in the browsing cache, as drawing it would have.
    static func browse(key: String) throws {
        let file = browsedFile(for: key)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try tileData.write(to: file, options: .atomic)
    }

    static func isBrowsed(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: browsedFile(for: key).path)
    }

    /// Ages a tile on disk, so eviction order — which is by modification date,
    /// i.e. when the tile was last fetched — can be driven without waiting.
    static func age(key: String, byDays days: Double) throws {
        for file in [browsedFile(for: key), savedFile(for: key)]
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
                ofItemAtPath: file.path
            )
        }
    }

    static func isSaved(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: savedFile(for: key).path)
    }
}

/// Whether this process can reach the App Group container the widget payload
/// lives in. Present in the real app (and in a test host that
/// inherits its entitlements), absent if the capability is ever dropped — in
/// which case the feed suites skip rather than fail for the wrong reason.
enum SharedStoreProbe {
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) != nil
    }
}

/// Runs `work` off the main thread. The tile pipeline asserts it isn't on
/// main (see `assertOffMainThread`), and Swift Testing runs these suites
/// main-actor-isolated by default, so anything touching that pipeline has to
/// hop first.
func offMain<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}
