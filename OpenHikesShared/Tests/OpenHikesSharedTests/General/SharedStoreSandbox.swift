//
//  SharedStoreSandbox.swift
//  OpenHikesSharedTests
//
//  Binds ``SharedStore``'s container seam to a throwaway directory for the
//  duration of one test, and builds the payloads the suites round trip.
//

import Foundation
@testable import OpenHikesShared
import Synchronization
import Testing

/// Runs `body` with ``SharedStore`` resolving into a directory of its own,
/// handing it that directory so a test can inspect the files by hand.
///
/// Every path in the store is derived from the container, so binding it is
/// enough to redirect the whole type. The directory is created up front —
/// `SharedStore` assumes its container already exists, which on a device it
/// always does — and removed on the way out whether or not the test failed.
/// Declared `throws` rather than `rethrows` so a test whose body happens not
/// to throw still writes `try`, and adding one throwing call to it later is
/// not a diff on this line.
func withSharedStoreSandbox<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let root = SharedStoreSandbox.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    return try SharedStore.$containerOverride.withValue({ root }, operation: { try body(root) })
}

/// The async twin of ``withSharedStoreSandbox(_:)``.
///
/// A task-local binding is inherited by structured children, so a `body` that
/// opens a task group sees the same container from every one of them. It would
/// *not* reach a `Task.detached`, which is why the concurrency test uses a
/// group rather than detaching.
func withSharedStoreSandbox<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let root = SharedStoreSandbox.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    return try await SharedStore.$containerOverride.withValue({ root }, operation: { try await body(root) })
}

/// Runs `body` with every ``SharedStoreDiagnostic`` it provokes collected,
/// so a test can assert not only that a payload was refused but that somebody
/// was told. The sink is additive — the refusal still reaches the unified log
/// — so this cannot pass by muting what it measures.
func withSharedStoreDiagnostics<Result>(
    _ body: () throws -> Result
) rethrows -> (result: Result, diagnostics: [SharedStoreDiagnostic]) {
    let collected = Mutex<[SharedStoreDiagnostic]>([])
    let sink: @Sendable (SharedStoreDiagnostic) -> Void = { diagnostic in
        collected.withLock { $0.append(diagnostic) }
    }
    let result = try SharedStoreDiagnostics.$sink.withValue(sink, operation: body)
    return (result, collected.withLock { $0 })
}

/// Runs `body` with ``SharedStore`` resolving to no container at all — the
/// state of a target whose App Group capability has not been wired up.
func withoutSharedStoreContainer<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    try SharedStore.$containerOverride.withValue({ nil }, operation: body)
}

// Fixture coordinates, distances and pixel sizes below are arbitrary but have
// to look like a real walk in the Chiemgau Alps, so naming each one would add
// a constant per literal and explain nothing. Same treatment as the app
// bundle's own fixture factory.
// swiftlint:disable no_magic_numbers
enum SharedStoreSandbox {
    static func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static let trailFileName = "trail-snapshot.json"
    static let recordingFileName = "recording-snapshot.json"
    static let basemapSetFileName = "trail-basemaps.json"
    static let basemapDirectoryName = "basemaps"

    static func trailSnapshot(
        hikeID: UUID = UUID(),
        title: String = "Thumsee Loop",
        pointCount: Int = 3,
        liveFix: SharedTrailSnapshot.LiveFix? = nil
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: hikeID,
            title: title,
            tintHex: "#2E7D32",
            totalDistanceMeters: 8420,
            polyline: polyline(pointCount),
            elevationLowMeters: 610,
            elevationHighMeters: 1122,
            elevationGainMeters: 512,
            liveFix: liveFix,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func recordingSnapshot(
        sessionID: UUID = UUID(),
        pointCount: Int = 3,
        isCapturingFixes: Bool = true
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            distanceMeters: 1240,
            pointCount: pointCount,
            polyline: polyline(pointCount),
            isCapturingFixes: isCapturingFixes,
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600)
        )
    }

    static func basemapSet(
        hikeID: UUID = UUID(),
        fileNames: [String] = ["thumsee-square-light.png"]
    ) -> TrailBasemapSet {
        let coverage = UnitMercatorRect(originX: 0.51, originY: 0.34, width: 0.01, height: 0.01)
        return TrailBasemapSet(
            hikeID: hikeID,
            coverage: coverage,
            images: fileNames.map { fileName in
                TrailBasemap(
                    fileName: fileName,
                    variant: .square,
                    appearance: .light,
                    pixelWidth: 320,
                    pixelHeight: 320,
                    visibleRect: coverage
                )
            },
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func polyline(_ count: Int) -> [SharedTrailSnapshot.CodableCoordinate] {
        (0 ..< count).map { index in
            SharedTrailSnapshot.CodableCoordinate(
                latitude: 47.7 + Double(index) * 0.0005,
                longitude: 12.85 + Double(index) * 0.0005
            )
        }
    }

    /// A snapshot re-read as a mutable JSON object, so a test can rename,
    /// retype or add a key and hand the result back to ``SharedStore`` exactly
    /// as a future build's encoder would have written it.
    static func encodedObject(_ snapshot: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    static func readObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }
}

extension SharedRecordingFix {
    static func sample(sessionID: UUID = UUID(), index: Int = 0) -> SharedRecordingFix {
        SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.7 + Double(index) * 0.0005,
            longitude: 12.85 + Double(index) * 0.0005,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            horizontalAccuracy: 8
        )
    }
}
// swiftlint:enable no_magic_numbers
