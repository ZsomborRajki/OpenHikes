//
//  SharedStoreSchemaTests.swift
//  OpenHikesSharedTests
//
//  Neither payload the App Group carries has a version field, so the only
//  thing standing between a schema change and a blank widget is what
//  `JSONDecoder` happens to tolerate. These tests write the JSON a future — or
//  a past — build would have produced and read it back through SharedStore,
//  so the tolerance is measured rather than assumed.
//
//  Establishing the behaviour is the point; adding a version field is a
//  product decision and is deliberately not made here.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared store schema evolution")
struct SharedStoreSchemaTests {
    // MARK: What is safe

    /// The forward-compatible case, and the one the app relies on every time
    /// the widget is a version behind the app that wrote the file: a newer
    /// build adds a field, an older reader ignores it and keeps drawing.
    @Test("a key the reader has never heard of is ignored")
    func unknownKeyIsIgnored() throws {
        try withSharedStoreSandbox { root in
            let snapshot = SharedStoreSandbox.trailSnapshot()
            var object = try SharedStoreSandbox.encodedObject(snapshot)
            object["surfaceBreakdown"] = ["gravel": 0.6, "asphalt": 0.4]
            object["difficultyGrade"] = "T2"
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            #expect(SharedStore.load() == snapshot)
        }
    }

    /// The other safe direction, and the reason a field is worth introducing
    /// as optional: an older writer omits it entirely and the newer reader
    /// decodes it as `nil` rather than failing.
    @Test("an optional key that is absent decodes as absent")
    func absentOptionalKeyDecodes() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object.removeValue(forKey: "elevationGainMeters")
            object.removeValue(forKey: "elevationHighMeters")
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            let loaded = try #require(SharedStore.load())
            #expect(loaded.elevationGainMeters == nil)
            #expect(loaded.elevationHighMeters == nil)
            #expect(loaded.totalDistanceMeters == 8420)
        }
    }

    // MARK: What is not

    /// The headline case, and the one versioning does *not* fix: a rename
    /// fails to decode before any version is consulted, so `load()` still
    /// answers `nil` and the widget still draws its placeholder. What changed
    /// is that the refusal now names the key it could not find, so the cause
    /// is one Console search away rather than a bisect. The file itself is
    /// untouched — intact, valid JSON, exactly as long as it was — which is
    /// why nothing but the diagnostic distinguishes this from an empty
    /// container.
    @Test("a renamed required key reads as no trail, and says which key")
    func renamedRequiredKeyNamesTheKey() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object["routeDistanceMeters"] = object.removeValue(forKey: "totalDistanceMeters")
            try SharedStoreSandbox.write(object, to: url)

            let (loaded, diagnostics) = withSharedStoreDiagnostics { SharedStore.load() }
            #expect(loaded == nil)
            #expect(diagnostics == [
                .decodeFailed(
                    file: SharedStoreSandbox.trailFileName,
                    detail: "missing key 'totalDistanceMeters' at root"
                ),
            ])

            let bytes = try Data(contentsOf: url)
            #expect(!bytes.isEmpty)
            #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: bytes) }
        }
    }

    @Test("a required key that changed type silently reads as no trail at all")
    func retypedKeyReadsAsNothing() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object["totalDistanceMeters"] = "8420 m"
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            #expect(SharedStore.load() == nil)
        }
    }

    @Test("a required key that was dropped silently reads as no trail at all")
    func removedRequiredKeyReadsAsNothing() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            object.removeValue(forKey: "tintHex")
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            #expect(SharedStore.load() == nil)
        }
    }

    /// The blast radius is not limited to the top level. `CodableCoordinate`
    /// is nested inside every polyline point and inside the live fix, so
    /// renaming one of its two keys takes the whole snapshot down — and it is
    /// the kind of type that looks safe to tidy up precisely because it is
    /// small and has no behaviour.
    @Test("renaming a key on a nested type takes the whole snapshot with it")
    func renamedNestedKeyReadsAsNothing() throws {
        try withSharedStoreSandbox { root in
            var object = try SharedStoreSandbox.encodedObject(SharedStoreSandbox.trailSnapshot())
            let polyline = try #require(object["polyline"] as? [[String: Any]])
            object["polyline"] = polyline.map { point -> [String: Any] in
                var renamed = point
                renamed["lat"] = renamed.removeValue(forKey: "latitude")
                return renamed
            }
            try SharedStoreSandbox.write(object, to: root.appendingPathComponent(SharedStoreSandbox.trailFileName))

            #expect(SharedStore.load() == nil)
        }
    }

    @Test("a renamed key on the basemap manifest silently reads as no basemaps")
    func renamedBasemapKeyReadsAsNothing() throws {
        try withSharedStoreSandbox { root in
            let set = SharedStoreSandbox.basemapSet()
            var object = try SharedStoreSandbox.encodedObject(set)
            object["trailID"] = object.removeValue(forKey: "hikeID")
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.basemapSetFileName)
            )

            #expect(SharedStore.loadBasemapSet(for: set.hikeID) == nil)
        }
    }

    // MARK: What a rename costs beyond a blank widget

    /// The recording payload's failure is worse than the trail's, because it
    /// is not only read for drawing. `appendPendingRecordingFix` decodes the
    /// recording snapshot to check the fix belongs to the session still
    /// capturing — so a rename does not merely blank the widget, it stops the
    /// widget's own fixes reaching the app at all. Unlike `loadRecording()`,
    /// this path does at least raise rather than answer `nil`, which is the
    /// only diagnostic a schema break produces anywhere in this file.
    @Test("a renamed recording key stops the widget's fixes reaching the app")
    func renamedRecordingKeyBreaksFixAppend() throws {
        try withSharedStoreSandbox { root in
            let session = UUID()
            var object = try SharedStoreSandbox.encodedObject(
                SharedStoreSandbox.recordingSnapshot(sessionID: session)
            )
            object["recordingID"] = object.removeValue(forKey: "sessionID")
            try SharedStoreSandbox.write(
                object,
                to: root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            )

            #expect(SharedStore.loadRecording() == nil)
            #expect(throws: (any Error).self) {
                try SharedStore.appendPendingRecordingFix(.sample(sessionID: session))
            }
        }
    }

    /// And the file must not be able to outlive the recording it claims to
    /// describe. `clearRecording(sessionID:)` decides by matching the session
    /// it decoded, and this is the only clear the stop path calls — so bytes
    /// that decode to nothing used to veto their own removal and become
    /// permanent, raising from every subsequent append. Unreadable bytes name
    /// no session, so they cannot be a different recording's, and they go.
    @Test("an undecodable recording snapshot cannot outlive the recording it describes")
    func undecodableRecordingSnapshotIsCleared() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            let session = UUID()
            var object = try SharedStoreSandbox.encodedObject(
                SharedStoreSandbox.recordingSnapshot(sessionID: session)
            )
            object["recordingID"] = object.removeValue(forKey: "sessionID")
            try SharedStoreSandbox.write(object, to: url)

            try SharedStore.clearRecording(sessionID: session)

            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The other half of that: a *readable* snapshot belonging to a different
    /// session still survives, so the fallback above widened the unreadable
    /// case only and did not turn the session argument into decoration.
    @Test("a readable snapshot for another session still survives the clear")
    func otherSessionsSnapshotSurvivesTheClear() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            let snapshot = SharedStoreSandbox.recordingSnapshot()
            try SharedStore.saveRecording(snapshot)

            try SharedStore.clearRecording(sessionID: UUID())

            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(SharedStore.loadRecording() == snapshot)
        }
    }
}
