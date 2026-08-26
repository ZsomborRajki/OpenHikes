//
//  PhotoDiscoveryFixtures.swift
//  OpenHikesTests
//
//  The stand-ins the discovery suite runs against: a photo library that
//  answers whatever it was built with, a photo store rooted somewhere
//  disposable, and a straight-line walk with a timestamp on every point.
//
//  Kept beside the suite rather than inside it so that what a test reads as is
//  the behaviour it pins, and because a fixture that has to be re-derived in
//  every file is a fixture that drifts. Everything here is `nonisolated` and
//  `Sendable`: the bundle is main-actor isolated, but suites run in parallel
//  and a fixture built in one must be readable from another.
//

import Foundation
@testable import OpenHikes
import Synchronization

#if canImport(UIKit)
import UIKit
#endif

/// A walk of ten evenly spaced, evenly timed points, and the moments along it.
nonisolated enum PhotoDiscoveryFixture {
    static let latitude: Double = 47.6300
    static let longitude: Double = 12.8600
    static let latitudeStep = 0.001
    static let stepSeconds: TimeInterval = 60
    static let stepCount = 10
    /// An arbitrary but fixed moment: mid-2025, so a test never depends on
    /// when it is run.
    static let epochSeconds: TimeInterval = 1_750_000_000
    static let epoch = Date(timeIntervalSince1970: epochSeconds)

    private static let sampleSide = 8

    static let route: [RouteCoordinate] = (0..<stepCount).map { index in
        RouteCoordinate(
            latitude: latitude + latitudeStep * Double(index),
            longitude: longitude,
            elevation: nil,
            timestamp: epoch.addingTimeInterval(stepSeconds * Double(index))
        )
    }

    /// A moment expressed in route points rather than in seconds, so a test
    /// says where on the walk it means rather than doing the arithmetic.
    static func date(atStep step: Double) -> Date {
        epoch.addingTimeInterval(stepSeconds * step)
    }

    static func asset(
        _ identifier: String,
        atStep step: Double
    ) -> PhotoLibraryAsset {
        PhotoLibraryAsset(
            localIdentifier: identifier,
            createdAt: date(atStep: step)
        )
    }

    /// Genuinely decodable bytes — the store asks ImageIO what they are, so
    /// filler would not get past it.
    static func sampleImageData() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: sampleSide, height: sampleSide)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }
}

/// A photo library that answers whatever it was built with, and remembers what
/// it was asked.
///
/// Counting the calls is half the point: the orderings this feature has to get
/// right are all about *not* asking — no permission prompt on a hike that
/// cannot be matched, no fetch after a refusal — and an assertion that
/// something never happened needs a witness.
nonisolated final class StubPhotoLibraryFixture: PhotoLibraryReading {
    struct Calls: Sendable {
        var accessRequests = 0
        var fetches = 0
        var dataReads = 0
        var lastWindow: ClosedRange<Date>?
    }

    let access: PhotoLibraryAccess
    let assets: [PhotoLibraryAsset]
    /// Identifiers whose bytes cannot be read, standing in for an asset that
    /// only exists in iCloud with no connection to reach it.
    let unreadable: Set<String>
    let calls = Mutex(Calls())

    init(
        access: PhotoLibraryAccess = .granted,
        assets: [PhotoLibraryAsset] = [],
        unreadable: Set<String> = []
    ) {
        self.access = access
        self.assets = assets
        self.unreadable = unreadable
    }

    // Async because the protocol is, not because these bodies suspend: a real
    // library is a cross-process query, this one is four stored properties.
    // swiftlint:disable async_without_await
    func requestAccess() async -> PhotoLibraryAccess {
        calls.withLock { $0.accessRequests += 1 }
        return access
    }

    func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset] {
        calls.withLock { calls in
            calls.fetches += 1
            calls.lastWindow = window
        }
        return assets.filter { window.contains($0.createdAt) }
    }

    func thumbnail(
        for localIdentifier: String,
        maxPixelSize: Int
    ) async -> LoadedPhotoImage? {
        nil
    }

    func imageData(for localIdentifier: String) async -> Data? {
        calls.withLock { $0.dataReads += 1 }
        guard !unreadable.contains(localIdentifier) else { return nil }
        return PhotoDiscoveryFixture.sampleImageData()
    }
    // swiftlint:enable async_without_await
}

/// A photo store with its own directory, removed when the test ends.
///
/// Never `HikePhotoStore.shared`: both unit bundles are hosted by the app, so
/// it is running and writing into the real one while these suites read.
nonisolated final class PhotoStoreSandbox: Sendable {
    let root: URL
    let store: HikePhotoStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "photo-discovery-\(UUID().uuidString)",
                isDirectory: true
            )
        store = HikePhotoStore(storageRoot: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
