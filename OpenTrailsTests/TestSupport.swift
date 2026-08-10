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

    /// An image with no backing bitmap — what the auto-save path's encode
    /// step can't turn into bytes. Stands in for the HEIC/PNG encode failures
    /// that motivated the fallback in `encodedForDurableStorage`.
    static func unencodableTileImage() -> TileImage {
        TileImage()
    }

    /// A 1×1 tile image that really encodes — what the auto-save path is
    /// handed in production, minus the 256×256.
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

/// Whether this process can reach the App Group container the widget and
/// Watch payload live in. Present in the real app (and in a test host that
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
