//
//  SharedPayloadShapeTests.swift
//  OpenHikesSharedTests
//
//  A golden record of what each App Group payload looks like on disk.
//
//  The version field these payloads now carry catches a *declared* schema
//  break: a reader refuses a payload that announces a version it does not
//  understand, and says so. Nothing caught an *undeclared* one, which is the
//  likelier mistake. Rename `totalDistanceMeters`, and every other test in
//  this package still passes — they build their payloads by hand, so they
//  simply rename along with it. The break surfaces on a walker's phone, as a
//  widget that draws its placeholder and never stops.
//
//  This suite is the second gate, and it only works because it stands behind
//  a first one. Renaming a property changes the memberwise initialiser's
//  argument label, so the fixtures below stop compiling — and the obvious way
//  to make them compile again is to rename the call too. That is the moment
//  this suite exists for: the expectation is still spelled the old way, the
//  test goes red, and the message says what the on-disk contract just did and
//  what the two acceptable answers are. Without it, updating the label turns
//  everything green and the break ships.
//
//  Three things about the encoding were measured rather than assumed, and the
//  fixtures depend on all three:
//
//  * `JSONEncoder` omits a `nil` optional entirely — no key, not a `null`. A
//    fixture built with the initialisers' defaults would therefore describe a
//    shape missing `elevationGainMeters`, `liveFix`, `course` and every other
//    optional: precisely the keys a rename would slip past unnoticed. Every
//    optional here is populated on purpose, and `everyStoredPropertyIsInTheShape`
//    fails if a newly added one is not.
//  * Arrays are described by their first element, so a fixture with an empty
//    `polyline` would hide a rename one level down. Each is non-empty, and an
//    empty one is recorded in the shape as an explicit hole rather than
//    silently contributing nothing.
//  * `Date` has no JSON form of its own. A bare `JSONEncoder` writes it as a
//    number, which is what these expectations record — so changing
//    `dateEncodingStrategy` (to `.iso8601`, say) turns every date into a
//    string and fails here too. That is worth having: a date strategy is the
//    one encoder setting that can break every payload at once while looking
//    like a formatting preference.
//
//  What this deliberately does not claim to catch is a `Double` becoming an
//  `Int` or the reverse. JSON has a single number type, and `JSONEncoder`
//  writes `Double(3)` as `3` — byte-identical to `Int(3)` — so no test at
//  this level can tell them apart. Nor is that change generally fatal:
//  measured, a `Double` reader decodes an integer-written field and an `Int`
//  reader decodes a whole-numbered one, and only a genuinely fractional value
//  meeting an `Int` reader throws. The compiler is the gate for that one —
//  narrowing a property's type stops these fixtures compiling.
//
//  On ``TrailBasemapSet``: it is exempt from *versioning*, deliberately, and
//  is not exempt from this. Those are different questions with different
//  costs. A version field is a runtime refusal, and refusing regenerable
//  state that would have decoded perfectly well buys nothing. A shape guard
//  costs nothing at runtime at all — it is a signal at review time — and the
//  break it names is real: an undecodable manifest sends
//  ``TrailBasemapRenderer`` back through a full MapKit re-render of every
//  variant and appearance. That self-heals on the next render only because
//  the app and the widget always ship in one bundle and therefore always
//  agree; that assumption is load-bearing and unobserved, and this is the
//  test that would notice the day it stopped holding.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared payload shape")
struct SharedPayloadShapeTests {
    @Test("the trail snapshot's on-disk shape is unchanged")
    func trailSnapshotShapeIsUnchanged() throws {
        try expectShape(
            of: PayloadShapeFixture.trailSnapshot,
            named: "SharedTrailSnapshot",
            versionedBy: "SharedTrailSnapshot.currentSchemaVersion",
            matches: [
                "elevationGainMeters: number",
                "elevationHighMeters: number",
                "elevationLossMeters: number",
                "elevationLowMeters: number",
                "hikeID: string",
                "liveFix.coordinate.latitude: number",
                "liveFix.coordinate.longitude: number",
                "liveFix.distanceAlongRouteMeters: number",
                "liveFix.elevationMeters: number",
                "liveFix.offRouteMeters: number",
                "liveFix.timestamp: number",
                "polyline[].latitude: number",
                "polyline[].longitude: number",
                "schemaVersion: number",
                "tintHex: string",
                "title: string",
                "totalDistanceMeters: number",
                "updatedAt: number",
            ]
        )
    }

    @Test("the recording snapshot's on-disk shape is unchanged")
    func recordingSnapshotShapeIsUnchanged() throws {
        try expectShape(
            of: PayloadShapeFixture.recordingSnapshot,
            named: "SharedRecordingSnapshot",
            versionedBy: "SharedRecordingSnapshot.currentSchemaVersion",
            matches: [
                "averageSpeedMetersPerSecond: number",
                "distanceMeters: number",
                "elevationGainMeters: number",
                "isCapturingFixes: bool",
                "pointCount: number",
                "polyline[].latitude: number",
                "polyline[].longitude: number",
                "schemaVersion: number",
                "sessionID: string",
                "startedAt: number",
                "updatedAt: number",
            ]
        )
    }

    /// Carries no version of its own — it is an element of a bare array, so
    /// there is no envelope to put one in without restructuring the file the
    /// widget appends to. That makes the shape guard the only guard it has.
    @Test("the pending recording fix's on-disk shape is unchanged")
    func recordingFixShapeIsUnchanged() throws {
        try expectShape(
            of: PayloadShapeFixture.recordingFix,
            named: "SharedRecordingFix",
            versionedBy: nil,
            matches: [
                "course: number",
                "elevation: number",
                "horizontalAccuracy: number",
                "id: string",
                "latitude: number",
                "longitude: number",
                "sessionID: string",
                "speed: number",
                "timestamp: number",
            ]
        )
    }

    @Test("the basemap manifest's on-disk shape is unchanged")
    func basemapSetShapeIsUnchanged() throws {
        try expectShape(
            of: PayloadShapeFixture.basemapSet,
            named: "TrailBasemapSet",
            versionedBy: nil,
            matches: [
                "coverage.height: number",
                "coverage.originX: number",
                "coverage.originY: number",
                "coverage.width: number",
                "generatedAt: number",
                "hikeID: string",
                "images[].appearance: string",
                "images[].fileName: string",
                "images[].pixelHeight: number",
                "images[].pixelWidth: number",
                "images[].variant: string",
                "images[].visibleRect.height: number",
                "images[].visibleRect.originX: number",
                "images[].visibleRect.originY: number",
                "images[].visibleRect.width: number",
            ]
        )
    }

    /// Guards the guard. A shape is only as complete as the value it was taken
    /// from, and `JSONEncoder` writes no key at all for a `nil` optional — so
    /// a property added to one of these types and left unset in the fixture
    /// above would be absent from both the shape and the expectation, and the
    /// two would agree about a key that is never checked.
    @Test(
        "every stored property reaches the encoded shape",
        arguments: PayloadShapeFixture.everyPayload
    )
    func everyStoredPropertyIsInTheShape(payload: PayloadShapeFixture.Named) throws {
        let keys = try PayloadShape.topLevelKeys(of: payload.value)
        let declared = Mirror(reflecting: payload.value).children.compactMap(\.label)
        let missing = declared.filter { !keys.contains($0) }.sorted()

        #expect(
            missing.isEmpty,
            Comment(rawValue: """
            \(payload.name) has stored properties that never reach its encoded shape: \
            \(missing.joined(separator: ", ")).

            Either the fixture in PayloadShapeFixture leaves them nil — JSONEncoder \
            omits a nil optional entirely, so the shape test above cannot see them and \
            a rename would slip past it — or the type has grown custom CodingKeys, \
            which on a cross-process payload is itself worth a second look.

            Populate them in the fixture and add them to the expected shape.
            """)
        )
    }
}
