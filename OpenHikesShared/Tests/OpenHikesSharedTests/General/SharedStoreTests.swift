//
//  SharedStoreTests.swift
//  OpenHikesSharedTests
//
//  The App Group contract between OpenHikes and OpenWidgetExtension. Nothing
//  covered this type before, which mattered because every read here answers
//  `nil` on failure and every write swallows its error: a broken contract
//  presents as a blank widget, never as a crash or a log line.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared store")
struct SharedStoreTests {
    // MARK: Round trips

    @Test("a trail snapshot written by the app is what the widget reads back")
    func trailSnapshotRoundTrip() throws {
        try withSharedStoreSandbox { _ in
            let snapshot = SharedStoreSandbox.trailSnapshot(
                liveFix: SharedTrailSnapshot.LiveFix(
                    coordinate: .init(latitude: 47.702, longitude: 12.853),
                    distanceAlongRouteMeters: 2100,
                    offRouteMeters: 8,
                    timestamp: Date(timeIntervalSince1970: 1_700_001_000),
                    elevationMeters: 730
                )
            )
            SharedStore.save(snapshot)
            #expect(SharedStore.load() == snapshot)
        }
    }

    @Test("a recording snapshot written by the app is what the widget reads back")
    func recordingSnapshotRoundTrip() throws {
        try withSharedStoreSandbox { _ in
            let snapshot = SharedStoreSandbox.recordingSnapshot()
            try SharedStore.saveRecording(snapshot)
            #expect(SharedStore.loadRecording() == snapshot)
        }
    }

    @Test("a basemap set written by the app is what the widget reads back")
    func basemapSetRoundTrip() throws {
        try withSharedStoreSandbox { _ in
            let set = SharedStoreSandbox.basemapSet()
            SharedStore.saveBasemapSet(set)
            #expect(SharedStore.loadBasemapSet(for: set.hikeID) == set)
        }
    }

    // MARK: Absent, corrupt and cleared

    @Test("nothing written yet reads as nothing, rather than throwing")
    func loadingBeforeAnySave() throws {
        try withSharedStoreSandbox { _ in
            #expect(SharedStore.load() == nil)
            #expect(SharedStore.loadRecording() == nil)
            #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
            #expect(SharedStore.basemapImageData(named: "missing.png") == nil)
            let pending = try SharedStore.loadPendingRecordingFixes()
            #expect(pending.isEmpty)
        }
    }

    /// Both read paths run their decode through `try?`, so a file that is not
    /// valid JSON is indistinguishable from one that was never written. That
    /// is the right *behaviour* — a widget cannot recover from a torn file and
    /// must draw its placeholder either way — but it costs the diagnostic: a
    /// container full of unreadable bytes reports exactly as an empty one, and
    /// nothing on the device says which.
    @Test("a truncated file reads as nothing, rather than throwing")
    func loadingTruncatedBytes() throws {
        try withSharedStoreSandbox { root in
            let encoded = try JSONEncoder().encode(SharedStoreSandbox.trailSnapshot())
            let half = encoded.prefix(encoded.count / 2)
            try Data(half).write(to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))
            #expect(SharedStore.load() == nil)
        }
    }

    @Test("bytes that are not JSON at all read as nothing, rather than throwing")
    func loadingGarbageBytes() throws {
        try withSharedStoreSandbox { root in
            let garbage = Data("this is not a snapshot".utf8)
            try garbage.write(to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))
            try garbage.write(to: root.appendingPathComponent(SharedStoreSandbox.recordingFileName))
            try garbage.write(to: root.appendingPathComponent(SharedStoreSandbox.basemapSetFileName))
            #expect(SharedStore.load() == nil)
            #expect(SharedStore.loadRecording() == nil)
            #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
        }
    }

    @Test("clearing removes the trail the widget was drawing")
    func clearingRemovesTheTrail() throws {
        try withSharedStoreSandbox { _ in
            SharedStore.save(SharedStoreSandbox.trailSnapshot())
            try #require(SharedStore.load() != nil)
            SharedStore.clear()
            #expect(SharedStore.load() == nil)
        }
    }

    @Test("clearing takes the rendered basemaps with it")
    func clearingRemovesBasemaps() throws {
        try withSharedStoreSandbox { _ in
            let set = SharedStoreSandbox.basemapSet()
            SharedStore.saveBasemapSet(set)
            SharedStore.writeBasemapImage(Data("png".utf8), named: set.images[0].fileName)
            try #require(SharedStore.hasAllBasemapImages(in: set))

            SharedStore.clear()

            #expect(SharedStore.loadBasemapSet(for: set.hikeID) == nil)
            #expect(SharedStore.basemapImageData(named: set.images[0].fileName) == nil)
        }
    }

    /// `clear()` is scoped to the *tracked trail*, not to the container: a
    /// walker deselecting a hike mid-walk must not lose the recording their
    /// phone is still capturing. Nothing else asserts the boundary, and the
    /// two live one line apart.
    @Test("clearing the trail leaves a live recording alone")
    func clearingSparesTheRecording() throws {
        try withSharedStoreSandbox { _ in
            let recording = SharedStoreSandbox.recordingSnapshot()
            SharedStore.save(SharedStoreSandbox.trailSnapshot())
            try SharedStore.saveRecording(recording)

            SharedStore.clear()

            #expect(SharedStore.load() == nil)
            #expect(SharedStore.loadRecording() == recording)
        }
    }

    // MARK: No container

    /// The state of a target whose App Group capability has not been wired up.
    /// Every read answers `nil` and every write is a no-op, so the app runs
    /// without a widget rather than not running; the recording APIs are the
    /// exception and say so, because a fix that was never persisted is data
    /// loss and the caller has to know.
    @Test("with no container the reads answer nothing and the writes do nothing")
    func noContainerDegradesRatherThanCrashing() {
        withoutSharedStoreContainer {
            #expect(SharedStore.appGroupContainerURL() == nil)

            SharedStore.save(SharedStoreSandbox.trailSnapshot())
            SharedStore.saveBasemapSet(SharedStoreSandbox.basemapSet())
            SharedStore.clear()

            #expect(SharedStore.load() == nil)
            #expect(SharedStore.loadRecording() == nil)
            #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
            #expect(SharedStore.writeBasemapImage(Data("png".utf8), named: "a.png") == false)
            #expect(SharedStore.hasAllBasemapImages(in: SharedStoreSandbox.basemapSet()) == false)
        }
    }

    @Test("with no container the recording APIs say so rather than losing a fix silently")
    func noContainerThrowsFromTheRecordingAPIs() {
        withoutSharedStoreContainer {
            expectContainerUnavailable { try SharedStore.saveRecording(SharedStoreSandbox.recordingSnapshot()) }
            expectContainerUnavailable { try SharedStore.clearRecording() }
            expectContainerUnavailable { try SharedStore.appendPendingRecordingFix(.sample()) }
            expectContainerUnavailable { try SharedStore.loadPendingRecordingFixes() }
            expectContainerUnavailable { try SharedStore.removePendingRecordingFixes(ids: []) }
            expectContainerUnavailable {
                try SharedStore.claimRecordingWidgetSample(sessionID: UUID(), minimumInterval: 30)
            }
            expectContainerUnavailable { try SharedStore.clearPendingRecordingFixes() }
        }
    }
}

/// `SharedRecordingStoreError` is not `Equatable`, so the case has to be
/// matched by hand rather than passed to `#expect(throws:)` as a value.
private func expectContainerUnavailable(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> some Any
) {
    #expect(sourceLocation: sourceLocation) {
        _ = try body()
    } throws: { error in
        guard case SharedRecordingStoreError.containerUnavailable = error else { return false }
        return true
    }
}
