//
//  TestSupport.swift
//  OpenHikesTests
//
//  Fixtures shared across the suites: a couple of real-shaped trails, a
//  minimal in-memory SwiftData stack, and helpers for the tile pipeline
//  (which is documented as "must not run on main" and asserts as much).
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Synchronization
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum Fixture {
    nonisolated private enum RidgeRoute {
        static let startTimestamp: TimeInterval = 1_750_000_000
        static let longitude: Double = -122.0300
        static let lat1: Double = 37.3300
        static let lat2: Double = 37.3320
        static let lat3: Double = 37.3340
        static let lat4: Double = 37.3360
        static let lat5: Double = 37.3380
        static let lat6: Double = 37.3400
        static let ele1: Double = 100
        static let ele2: Double = 150
        static let ele3: Double = 220
        static let ele4: Double = 180
        static let ele5: Double = 260
        static let ele6: Double = 240
        static let secondsPerStep: Double = 60
    }

    nonisolated private enum LoopRoute {
        static let centerLatitude: Double = 47.6300
        static let centerLongitude: Double = 12.8600
        static let radius: Double = 0.0045 // ~500 m
        static let stepCount: Int = 36
        static let baseElevation: Double = 600
        static let elevationAmplitude: Double = 40
    }

    nonisolated private enum OutAndBackRoute {
        static let startLatitude: Double = 47.6300
        static let startLongitude: Double = 12.8600
        static let stepCount: Int = 20
        static let latStepSize: Double = 0.0005 // ~56 m per step
        static let eleStepSize: Double = 8
        static let baseElevation: Double = 600
    }

    nonisolated private enum AntimeridianRoute {
        static let latitude1: Double = -17.70
        static let longitude1: Double = 179.95
        static let latitude2: Double = -17.71
        static let longitude2: Double = -179.95
    }

    nonisolated private static func makeRidgeRoute() -> [RouteCoordinate] {
        let start = Date(timeIntervalSince1970: RidgeRoute.startTimestamp)
        let points: [(Double, Double, Double)] = [
            (RidgeRoute.lat1, RidgeRoute.longitude, RidgeRoute.ele1),
            (RidgeRoute.lat2, RidgeRoute.longitude, RidgeRoute.ele2),
            (RidgeRoute.lat3, RidgeRoute.longitude, RidgeRoute.ele3),
            (RidgeRoute.lat4, RidgeRoute.longitude, RidgeRoute.ele4),
            (RidgeRoute.lat5, RidgeRoute.longitude, RidgeRoute.ele5),
            (RidgeRoute.lat6, RidgeRoute.longitude, RidgeRoute.ele6),
        ]
        return points.enumerated().map { index, point in
            RouteCoordinate(
                latitude: point.0,
                longitude: point.1,
                elevation: point.2,
                timestamp: start.addingTimeInterval(Double(index) * RidgeRoute.secondsPerStep)
            )
        }
    }

    /// A short line due north near Cupertino: six points ~1.1 km apart end to
    /// end, one per minute, climbing and dipping twice. Small enough to reason
    /// about by hand, real enough that distances/gradients aren't degenerate.
    nonisolated static let ridgeRoute: [RouteCoordinate] = makeRidgeRoute()

    nonisolated private static func makeLoopRoute() -> [RouteCoordinate] {
        let center = CLLocationCoordinate2D(latitude: LoopRoute.centerLatitude, longitude: LoopRoute.centerLongitude)
        let radius = LoopRoute.radius
        var points = (0..<LoopRoute.stepCount).map { step -> RouteCoordinate in
            let angle = Double(step) / Double(LoopRoute.stepCount) * 2 * .pi
            return RouteCoordinate(
                latitude: center.latitude + radius * cos(angle),
                longitude: center.longitude + radius * sin(angle) / cos(center.latitude * .pi / 180),
                elevation: LoopRoute.baseElevation + LoopRoute.elevationAmplitude * sin(angle * 2)
            )
        }
        points.append(points[0]) // close the loop
        return points
    }

    /// A ~500 m-radius loop whose last point repeats its first — the geometry
    /// that makes route-matching ambiguous, and the reason
    /// `RouteProfile.nearestPoint` takes a continuity reference.
    nonisolated static let loopRoute: [RouteCoordinate] = makeLoopRoute()

    nonisolated private static func makeOutAndBackRoute() -> [RouteCoordinate] {
        let returnLegOffset = 1e-5
        let outbound = (0..<OutAndBackRoute.stepCount).map { step in
            RouteCoordinate(
                latitude: OutAndBackRoute.startLatitude + Double(step) * OutAndBackRoute.latStepSize,
                longitude: OutAndBackRoute.startLongitude,
                elevation: OutAndBackRoute.baseElevation + Double(step) * OutAndBackRoute.eleStepSize
            )
        }
        let returning = outbound.dropLast().reversed().map { point in
            RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude + returnLegOffset,
                elevation: point.elevation
            )
        }
        return outbound + returning
    }

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
    nonisolated static let outAndBackRoute: [RouteCoordinate] = makeOutAndBackRoute()

    /// A ~10 km walk in Fiji that steps across ±180°. Short on the ground, but
    /// the widest possible span if longitude is read as a plain `min`/`max`
    /// interval — which is the mistake both the bulk downloader and the
    /// auto-save corridor have to avoid, so they're both tested against this
    /// same trail.
    nonisolated static let antimeridianRoute: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: AntimeridianRoute.latitude1, longitude: AntimeridianRoute.longitude1),
        CLLocationCoordinate2D(latitude: AntimeridianRoute.latitude2, longitude: AntimeridianRoute.longitude2),
    ]

    /// The route as the map/downloader see it.
    nonisolated static func coordinates(_ route: [RouteCoordinate]) -> [CLLocationCoordinate2D] {
        route.map(\.clCoordinate)
    }

    /// A hike backed by an in-memory store, so `@Model` bookkeeping
    /// (`autoSavedTileKeys`, `offlineDownloads`) behaves as it does in the app.
    ///
    /// `configure` runs *after* the insert, and has to: those two live in the
    /// unmirrored ``HikeLocalState`` store, and ``Hike``'s passthroughs need a
    /// context to reach it. Configured before the insert they would be
    /// silently dropped, which is a fixture that lies rather than a test that
    /// fails.
    static func hike(
        in context: ModelContext,
        title: String = "Ridge Loop",
        route: [RouteCoordinate] = ridgeRoute,
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) -> Hike {
        let profile = RouteProfile(route: route)
        let hike = Hike(
            title: title,
            distanceMeters: profile.distances.last ?? 0,
            route: route
        )
        context.insert(hike)
        configure(hike)
        return hike
    }

    static func modelContainer() throws -> ModelContainer {
        try ModelContainer.openHikes(isStoredInMemoryOnly: true)
    }

    static func modelContext() throws -> ModelContext {
        ModelContext(try modelContainer())
    }

    private enum TileImageConstants {
        static let tilePoints: Double = 256.0
        // periphery:ignore - read only from the `canImport(AppKit)` branch
        // below, which this iPhone-only build never compiles.
        static let bitsPerSample: Int = 8
        // periphery:ignore - as above.
        static let samplesPerPixel: Int = 4
    }

    /// A tile at the size providers actually serve, for the questions where
    /// 1×1 gives the wrong answer — chiefly what a decoded tile costs in
    /// memory, where the whole point is that it dwarfs the compressed file.
    static func fullSizeTileImage(scale: CGFloat = 2) -> TileImage? {
        let points = TileImageConstants.tilePoints
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
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: TileImageConstants.bitsPerSample,
            samplesPerPixel: TileImageConstants.samplesPerPixel,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        let image = NSImage(size: CGSize(width: points, height: points))
        image.addRepresentation(rep)
        return image
        #else
        return nil
        #endif
    }

    nonisolated static func tileImage() -> TileImage? {
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

/// The bytes the tile pipeline moves around.
///
/// Auto-save no longer takes an image and encodes it, it moves the bytes a
/// fetch already cached, so a test that wants a tile to be savable has to put
/// those bytes where a fetch would have — see ``TileSandbox``.
nonisolated enum TileStore {
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
}

/// One test's private copy of the whole tile pipeline: a ``TileCache`` whose
/// two tiers live under a temporary directory, and an ``AutoSaveTileStore``
/// wired to it with an active hike of its own.
///
/// This is the seam the suites used to do without. `TileCache.shared` writes
/// into the host app's real `Caches`/`Application Support` pair and
/// `AutoSaveTileStore.shared` has exactly one active hike, so every suite that
/// touched either was mutating state its neighbours could see — and Swift
/// Testing runs top-level suites in parallel. A sandbox per suite makes that
/// impossible to get wrong: there is nothing shared left to corrupt.
///
/// `TileCache` keeps the directory names private, so they're restated here
/// along with the key→filename mapping; a change to either belongs in this
/// type too.
nonisolated final class TileSandbox: Sendable {
    private enum Constants {
        static let secondsPerDay: Double = 86_400
    }

    let root: URL
    let cache: TileCache
    let store: AutoSaveTileStore

    /// - Parameters:
    ///   - reachable: seeds the cache's connectivity flag. The cache never
    ///     watches `NWPathMonitor`, so a test isn't at the mercy of the
    ///     machine's own connection.
    ///   - sessionConfiguration: `nil` leaves the standard transport, which is
    ///     enough for the suites that place files by hand; pass
    ///     `StubTileProtocol.sessionConfiguration()` to script the responses.
    ///   - mutationKeyLimit: how many per-key deletion versions the cache
    ///     holds before compacting them into its epoch. Lower it to reach
    ///     compaction without sixteen thousand deletions.
    ///   - power: the power state the fetch policy sees. Fixed rather than
    ///     read from the process, so a suite that publishes Low Power Mode
    ///     cannot change what a tile suite running beside it decides.
    ///   - durableByteLimitScale: shrinks the licensed per-provider durable
    ///     ceilings so a quota test can reach one with a handful of tiles.
    init(
        reachable: Bool = true,
        sessionConfiguration: URLSessionConfiguration? = nil,
        mutationKeyLimit: Int = TileCache.mutationKeyVersionLimit,
        power: PowerState = PowerState(),
        durableByteLimitScale: Double = 1
    ) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilesandbox-\(UUID().uuidString)", isDirectory: true)
        cache = TileCache(
            storageRoot: root,
            sessionConfiguration: sessionConfiguration,
            monitorsNetwork: false,
            mutationKeyLimit: mutationKeyLimit,
            durableByteLimitScale: durableByteLimitScale
        ) { power }
        store = AutoSaveTileStore(tileCache: cache)
        if !reachable { cache.setReachable(false) }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func fileName(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
    }

    /// `OSMTiles` — where a tile fetched to draw the map lands, whether or not
    /// any hike will ever claim it.
    func browsedFile(for key: String) -> URL {
        root.appendingPathComponent("OSMTiles", isDirectory: true).appendingPathComponent(fileName(for: key))
    }

    /// `OSMTilesSaved` — where a tile kept for offline use lands, out of reach
    /// of the OS reclaiming storage.
    func savedFile(for key: String) -> URL {
        root.appendingPathComponent("OSMTilesSaved", isDirectory: true).appendingPathComponent(fileName(for: key))
    }

    func isBrowsed(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: browsedFile(for: key).path)
    }

    func isSaved(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: savedFile(for: key).path)
    }

    /// Puts a tile in the browsing cache, as drawing it would have.
    func browse(key: String) throws {
        try place(in: browsedFile(for: key))
    }

    /// Puts a tile in durable storage, as a previous session's save would have.
    func save(key: String) throws {
        try place(in: savedFile(for: key))
    }

    /// Puts a tile in a tier directly, optionally backdated.
    func place(in file: URL, agedByDays days: Double = 0) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try TileStore.tileData.write(to: file, options: .atomic)
        if days > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -days * Constants.secondsPerDay)],
                ofItemAtPath: file.path
            )
        }
    }

    /// Ages a tile on disk, so eviction order — which is by modification date,
    /// i.e. when the tile was last fetched — can be driven without waiting.
    func age(key: String, byDays days: Double) throws {
        for file in [browsedFile(for: key), savedFile(for: key)]
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -days * Constants.secondsPerDay)],
                ofItemAtPath: file.path
            )
        }
    }
}

/// Whether this process can reach the App Group container the widget payload
/// lives in. Present in the real app (and in a test host that
/// inherits its entitlements), absent if the capability is ever dropped — in
/// which case the feed suites skip rather than fail for the wrong reason.
///
/// Whether a skip is acceptable is `SuitePrecondition`'s question, not this
/// one's.
nonisolated enum SharedStoreProbe {
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) != nil
    }
}

/// Preconditions a suite can't create for itself, and what a run does when one
/// is missing.
///
/// A run that skipped a conditional suite prints the same "all tests passed" as
/// a run that executed it, so a dropped entitlement silently turns coverage off
/// rather than failing. Strict mode makes the difference visible: a missing
/// precondition is recorded as a failure. Without it the gap is still named in
/// the output — just not fatally, because a developer running the suite on a
/// machine that can't satisfy it is not the same event as coverage
/// disappearing from a shared build.
///
/// Turn it on with either
///
/// ```sh
/// xcodebuild test … "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"
/// ```
///
/// or by setting `OPENHIKES_REQUIRE_ALL_SUITES=1` in the scheme's test
/// action. Both exist because a simulator-hosted test bundle inherits nothing
/// from the shell that launched `xcodebuild`: the compilation condition is the
/// half that works from a command line, the environment variable the half that
/// works from Xcode.
enum SuitePrecondition {
    static let strictEnvironmentKey = "OPENHIKES_REQUIRE_ALL_SUITES"

    static var isStrict: Bool {
        #if REQUIRE_ALL_SUITES
        return true
        #else
        return ProcessInfo.processInfo.environment[strictEnvironmentKey] == "1"
        #endif
    }

    /// Reports a precondition this run could not satisfy.
    static func check(_ isSatisfied: Bool, _ description: String) {
        guard !isSatisfied else { return }
        let message = "Precondition not met: \(description)."
        if isStrict {
            Issue.record(Comment(rawValue: "\(message) The suites depending on it did not run."))
        } else {
            print("⚠︎ Skipped coverage — \(message) Set \(strictEnvironmentKey)=1 to make this a failure.")
        }
    }
}

/// Runs unconditionally, and is the only place a conditional suite's absence
/// is visible at all.
@Suite("Suite preconditions")
struct SuitePreconditionTests {
    @Test("the App Group the widget feeds are written to is reachable")
    func appGroupIsReachable() {
        SuitePrecondition.check(
            SharedStoreProbe.isAvailable,
            "the App Group container \(SharedStore.appGroupID) is unreachable, so the widget feed suites were skipped"
        )
    }
}

/// Runs `work` off the main thread. The tile pipeline asserts it isn't on
/// main (see `assertOffMainThread`), and Swift Testing runs these suites
/// main-actor-isolated by default, so anything touching that pipeline has to
/// hop first.
///
/// `@concurrent` rather than `Task.detached`: this stays inside the test's own
/// task, so a cancelled test cancels the work it is waiting on, and the
/// closure's typed throws propagate instead of needing a `Result` box.
@concurrent
func offMain<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
    try work()
}

/// A clock a test moves by hand.
///
/// The alternative — sleeping past a real interval — spends the interval on
/// every run and still only *probably* clears it, which is the definition of a
/// flaky test that is also a slow one.
nonisolated final class TestClock: Sendable {
    private enum Constants {
        // swiftlint:disable no_magic_numbers
        static let defaultStartTimestamp: TimeInterval = 1_750_000_000
        // swiftlint:enable no_magic_numbers
    }

    private let instant: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: Constants.defaultStartTimestamp)) {
        instant = Mutex(start)
    }

    var now: Date {
        instant.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        instant.withLock { $0 += interval }
    }

    /// Passed straight to the injection points that take `() -> Date`.
    var read: @Sendable () -> Date {
        { [self] in now }
    }
}

/// A deterministic `RandomNumberGenerator` (SplitMix64), so a test that sweeps
/// thousands of random values can be re-run on exactly the values that failed
/// it. Override the seed with `OPENHIKES_TEST_SEED` in the environment; the
/// tests that use it quote the seed in their failure messages.
struct SeededGenerator: RandomNumberGenerator {
    private enum SplitMix64 {
        // swiftlint:disable no_magic_numbers
        static let shift1: UInt64 = 30
        static let shift2: UInt64 = 27
        static let shift3: UInt64 = 31
        // swiftlint:enable no_magic_numbers
    }

    static let defaultSeed: UInt64 = ProcessInfo.processInfo.environment["OPENHIKES_TEST_SEED"]
        // swiftlint:disable:next no_magic_numbers
        .flatMap(UInt64.init) ?? 0x4F70_656E_5472_6169

    let seed: UInt64
    private var state: UInt64

    init(seed: UInt64 = defaultSeed) {
        self.seed = seed
        state = seed
    }

    mutating func next() -> UInt64 {
        // swiftlint:disable no_magic_numbers
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> SplitMix64.shift1)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> SplitMix64.shift2)) &* 0x94D0_49BB_1331_11EB
        // swiftlint:enable no_magic_numbers
        return z ^ (z >> SplitMix64.shift3)
    }
}
