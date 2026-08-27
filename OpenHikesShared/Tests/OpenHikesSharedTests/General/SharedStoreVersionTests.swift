//
//  SharedStoreVersionTests.swift
//  OpenHikesSharedTests
//
//  What the version field buys, and — as importantly — what it does not.
//  It cannot make a renamed key decode; that failure is covered next door in
//  the schema suite. What it does is stop this build interpreting bytes a
//  newer one wrote, and do it out loud.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared store versioning")
struct SharedStoreVersionTests {
    // MARK: What this build writes

    @Test("a payload this build writes announces this build's version")
    func writesTheCurrentVersion() throws {
        try withSharedStoreSandbox { root in
            SharedStore.save(SharedStoreSandbox.trailSnapshot())
            try SharedStore.saveRecording(SharedStoreSandbox.recordingSnapshot())

            let trail = try SharedStoreSandbox.readObject(
                at: root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            )
            let recording = try SharedStoreSandbox.readObject(
                at: root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            )
            #expect(trail["schemaVersion"] as? Int == SharedTrailSnapshot.currentSchemaVersion)
            #expect(recording["schemaVersion"] as? Int == SharedRecordingSnapshot.currentSchemaVersion)
        }
    }

    @Test("a payload that round trips keeps the version it was written with")
    func versionSurvivesTheRoundTrip() throws {
        try withSharedStoreSandbox { _ in
            SharedStore.save(SharedStoreSandbox.trailSnapshot())
            let loaded = try #require(SharedStore.load())
            #expect(loaded.schemaVersion == SharedTrailSnapshot.currentSchemaVersion)
            #expect(loaded.effectiveSchemaVersion == 1)
        }
    }

    // MARK: The payload already in the container

    /// The update that introduces versioning finds an unversioned payload in
    /// every existing user's container. Discarding it would blank a working
    /// widget to guard against a change that has not happened, so an absent
    /// version is version 0 and is accepted on the only evidence that matters:
    /// it decoded, which means every key this build requires was there.
    @Test("a payload written before versioning existed is still read")
    func legacyPayloadIsAccepted() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object.removeValue(forKey: "schemaVersion")
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.load() }
            let snapshot = try #require(loaded)
            #expect(snapshot.title == "Thumsee Loop")
            #expect(snapshot.schemaVersion == nil)
            #expect(snapshot.effectiveSchemaVersion == 0)
            #expect(diagnostics.isEmpty, "a legacy payload is expected, not exceptional")
        }
    }

    @Test("an unversioned recording snapshot is still read")
    func legacyRecordingPayloadIsAccepted() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.recordingSnapshot())
            object.removeValue(forKey: "schemaVersion")
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            )

            let snapshot = try #require(SharedStore.loadRecording())
            #expect(snapshot.effectiveSchemaVersion == 0)
            #expect(snapshot.pointCount == 3)
        }
    }

    /// The app can still append the widget's fixes against a legacy snapshot,
    /// which is the part that would hurt to get wrong: a walker mid-recording
    /// when the update installs would otherwise lose every fix the widget
    /// captured until they stopped and started again.
    @Test("a legacy recording snapshot still validates the widget's fixes")
    func legacyRecordingPayloadStillAcceptsFixes() throws {
        try withSharedStoreSandbox { root in
            let session = UUID()
            var object = try SharedStoreSandbox.encodedObject(
                SharedStoreSandbox.recordingSnapshot(sessionID: session)
            )
            object.removeValue(forKey: "schemaVersion")
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            )

            #expect(try SharedStore.appendPendingRecordingFix(.sample(sessionID: session)))
            let pending = try SharedStore.loadPendingRecordingFixes()
            #expect(pending.count == 1)
        }
    }

    // MARK: A payload from a newer build

    /// The case the version exists for, and the reason the version is peeked
    /// out of the raw bytes rather than read off the decoded payload: these
    /// bytes decode perfectly well as v1. Accepting them would read v2's
    /// fields with v1's meaning — a snapshot that is wrong rather than
    /// missing, which is the failure a walker cannot see.
    @Test("a payload from a newer build is refused even though it would decode")
    func newerPayloadIsRefused() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object["schemaVersion"] = SharedTrailSnapshot.currentSchemaVersion + 1
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.load() }
            #expect(loaded == nil)
            #expect(diagnostics == [
                .unsupportedSchemaVersion(
                    file: SharedStoreSandbox.trailFileName,
                    found: 2,
                    supported: 1
                ),
            ])
        }
    }

    @Test("a recording snapshot from a newer build is refused")
    func newerRecordingPayloadIsRefused() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.recordingSnapshot())
            object["schemaVersion"] = 99
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            )

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.loadRecording() }
            #expect(loaded == nil)
            #expect(diagnostics == [
                .unsupportedSchemaVersion(
                    file: SharedStoreSandbox.recordingFileName,
                    found: 99,
                    supported: 1
                ),
            ])
        }
    }

    /// A refusal on version has to be a refusal, not a deferral: the bytes
    /// stay exactly as the newer build left them. Rewriting or deleting them
    /// would destroy the newer build's state on a downgrade that the walker
    /// may well undo an hour later.
    @Test("refusing a newer payload leaves it untouched")
    func refusingLeavesTheBytesAlone() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object["schemaVersion"] = 2
            try SharedStoreSandbox.write(object, to: url)
            let before = try Data(contentsOf: url)

            #expect(SharedStore.load() == nil)

            #expect(try Data(contentsOf: url) == before)
        }
    }

    /// Bytes announcing a version this build understands but whose shape it
    /// does not get the version's benefit of the doubt — the gate is an upper
    /// bound, not a substitute for decoding.
    @Test("a payload at this version that does not decode is still refused, by decode")
    func currentVersionStillHasToDecode() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object.removeValue(forKey: "hikeID")
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.load() }
            #expect(loaded == nil)
            #expect(diagnostics == [
                .decodeFailed(file: SharedStoreSandbox.trailFileName, detail: "missing key 'hikeID' at root")
            ])
        }
    }

    /// A version that is not a number at all cannot be trusted as one, and
    /// falls through to the decoder — which refuses it for the type mismatch
    /// rather than silently reading it as version 0 and accepting it.
    @Test("a version that is not a number is refused rather than assumed")
    func nonNumericVersionIsRefused() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object["schemaVersion"] = "two"
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.load() }
            #expect(loaded == nil)
            #expect(diagnostics.count == 1)
            #expect(diagnostics.first?.summary.contains("schemaVersion") == true)
        }
    }

    // MARK: The manifest that is exempt

    /// `TrailBasemapSet` carries no version on purpose. It is derived state:
    /// the renderer treats an unreadable manifest exactly as it treats a
    /// missing image and re-renders, so a schema change costs one render
    /// rather than a blank widget. The exemption is asserted rather than
    /// assumed — a `schemaVersion` appearing in these bytes is just another
    /// unknown key, and is ignored.
    @Test("the basemap manifest ignores a version rather than obeying one")
    func basemapManifestIsExemptFromVersioning() throws {
        try withSharedStoreSandbox { root in
            let set = SharedStoreSandbox.basemapSet()
            var object = try SharedStoreSandbox.encodedObject(set)
            object["schemaVersion"] = 99
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.basemapSetFileName)
            )

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.loadBasemapSet(for: set.hikeID) }
            #expect(loaded == set)
            #expect(diagnostics.isEmpty)
        }
    }

    /// It is exempt from the version, not from the diagnostic. A manifest
    /// nothing can decode is re-rendered on every timeline reload for as long
    /// as it sits there, and a battery cost that presents as nothing at all is
    /// the kind worth being able to see.
    @Test("an undecodable basemap manifest still says so")
    func basemapManifestStillReportsADecodeFailure() throws {
        try withSharedStoreSandbox { root in
            let set = SharedStoreSandbox.basemapSet()
            var object = try SharedStoreSandbox.encodedObject(set)
            object["trailID"] = object.removeValue(forKey: "hikeID")
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.basemapSetFileName)
            )

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.loadBasemapSet(for: set.hikeID) }
            #expect(loaded == nil)
            #expect(diagnostics == [
                .decodeFailed(
                    file: SharedStoreSandbox.basemapSetFileName,
                    detail: "missing key 'hikeID' at root"
                ),
            ])
        }
    }

    // MARK: What the diagnostic reads like

    @Test("every refusal names the file and the cause in one line")
    func diagnosticsReadAsSentences() {
        #expect(
            SharedStoreDiagnostic
                .decodeFailed(file: "trail-snapshot.json", detail: "missing key 'title' at root")
                .summary == "trail-snapshot.json could not be decoded: missing key 'title' at root"
        )
        #expect(
            SharedStoreDiagnostic
                .unsupportedSchemaVersion(file: "recording-snapshot.json", found: 4, supported: 1)
                .summary == """
                recording-snapshot.json was written by a newer build \
                (schema v4; this build reads v1)
                """
        )
    }
}

extension SharedStoreVersionTests {
    /// The app's live-fix path loads the stored snapshot, moves the fix and
    /// saves it back. If the version travelled with the value rather than
    /// being stamped on write, a container that was unversioned before this
    /// shipped would stay unversioned through every walk that followed, and
    /// the legacy question would be re-decided forever instead of once.
    @Test("re-saving a payload loaded from a legacy container upgrades it")
    func resavingALegacyPayloadStampsTheCurrentVersion() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object.removeValue(forKey: "schemaVersion")
            try SharedStoreSandbox.write(object, to: url)

            var loaded = try #require(SharedStore.load())
            try #require(loaded.schemaVersion == nil)
            loaded.updatedAt = Date(timeIntervalSince1970: 1_700_009_999)
            SharedStore.save(loaded)

            let rewritten = try SharedStoreSandbox.readObject(at: url)
            #expect(rewritten["schemaVersion"] as? Int == SharedTrailSnapshot.currentSchemaVersion)
            #expect(SharedStore.load()?.schemaVersion == SharedTrailSnapshot.currentSchemaVersion)
        }
    }
}
