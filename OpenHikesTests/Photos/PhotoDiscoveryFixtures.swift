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
///
/// Its access is mutable rather than fixed because permission is not a
/// property of a run: it can be taken away between the prompt and the fetch,
/// and widened by the limited-library picker while the sheet is up. Both are
/// states this flow has to survive, and neither can be staged by a stub that
/// answers the same thing forever.
nonisolated final class StubPhotoLibraryFixture: PhotoLibraryReading {
    struct Calls: Sendable {
        var accessRequests = 0
        var fetches = 0
        var dataReads = 0
        var limitedPickerPresentations = 0
        var lastWindow: ClosedRange<Date>?
    }

    /// Everything this library can be made to answer with, in one box so the
    /// stub is `Sendable` without being immutable.
    private struct State: Sendable {
        var access: PhotoLibraryAccess
        var assets: [PhotoLibraryAsset]
    }

    let unreadable: Set<String>
    /// What the user shares when they are handed the limited-library picker.
    /// Empty stands for closing it without changing anything.
    let assetsSharedByPicker: [PhotoLibraryAsset]
    let calls = Mutex(Calls())
    /// Held at, so a test can arrange something while the flow is genuinely
    /// mid-fetch rather than before or after one.
    private let fetchGate: TestGate?
    private let state: Mutex<State>

    init(
        access: PhotoLibraryAccess = .granted,
        assets: [PhotoLibraryAsset] = [],
        unreadable: Set<String> = [],
        assetsSharedByPicker: [PhotoLibraryAsset] = [],
        fetchGate: TestGate? = nil
    ) {
        self.unreadable = unreadable
        self.assetsSharedByPicker = assetsSharedByPicker
        self.fetchGate = fetchGate
        state = Mutex(State(access: access, assets: assets))
    }

    var access: PhotoLibraryAccess { state.withLock(\.access) }

    /// Stands for the user turning this app's photo access off in Settings
    /// while the app is looking through their library.
    func revokeAccess() {
        state.withLock { state in
            state.access = .denied
            state.assets = []
        }
    }

    // Async because the protocol is, not because these bodies suspend: a real
    // library is a cross-process query, this one is a handful of stored
    // properties.
    // swiftlint:disable async_without_await
    func requestAccess() async -> PhotoLibraryAccess {
        calls.withLock { $0.accessRequests += 1 }
        return access
    }
    // swiftlint:enable async_without_await

    func currentAccess() -> PhotoLibraryAccess { access }

    func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset] {
        calls.withLock { calls in
            calls.fetches += 1
            calls.lastWindow = window
        }
        await fetchGate?.wait()
        return state.withLock(\.assets).filter { window.contains($0.createdAt) }
    }

    // swiftlint:disable async_without_await
    /// Presents nothing; records that it was asked, and shares whatever this
    /// stub was built to share.
    ///
    /// The presenter is ignored on purpose — a test has no screen, so it has
    /// no view controller, and a presenter with no anchor is exactly what the
    /// shipping reader refuses to present from.
    @MainActor
    func presentLimitedLibraryPicker(from _: LimitedLibraryPresenter) async {
        calls.withLock { $0.limitedPickerPresentations += 1 }
        state.withLock { current in
            current.assets += assetsSharedByPicker
        }
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

/// A one-shot gate: whoever reaches it waits there until a test opens it.
///
/// A continuation rather than a sleep or a count of yields, for the reason
/// ``settleDelegateHop(until:sourceLocation:condition:)`` exists: a yield buys
/// an amount of progress that depends on how busy the machine is, while this
/// resumes when the test says so and at no other moment. That is the only
/// version of "caught mid-flight" that does not depend on load.
nonisolated final class TestGate: Sendable {
    private enum State {
        case idle
        case opened
        case waiting(CheckedContinuation<Void, Never>)
    }

    private let state = Mutex(State.idle)

    /// Whether something is being held here right now.
    var isHolding: Bool {
        state.withLock { state in
            if case .waiting = state { true } else { false }
        }
    }

    /// Suspends until ``open()``, or returns at once if it has already been
    /// opened — so a gate can never deadlock a flow that reached it late.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let passStraightThrough = state.withLock { state -> Bool in
                guard case .idle = state else { return true }
                state = .waiting(continuation)
                return false
            }
            if passStraightThrough { continuation.resume() }
        }
    }

    func open() {
        let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .opened }
            guard case let .waiting(continuation) = state else { return nil }
            return continuation
        }
        held?.resume()
    }
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
