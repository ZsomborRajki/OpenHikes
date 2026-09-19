//
//  WatchPayloadShapeTests.swift
//  OpenHikesSharedTests
//
//  A golden record of what each payload crossing the watch link looks like on
//  the wire, built on the same machinery ``SharedPayloadShapeTests`` uses for
//  the App Group's files — see that file's header for what a "shape" is and
//  for the three things about `JSONEncoder` these fixtures depend on.
//
//  Its own suite rather than four more cases in that one, because the hazard
//  is not the same size. Both sides of the App Group ship in one bundle and
//  are therefore always the same build; the two sides of *this* link are
//  separate binaries on separate devices that a hiker updates independently,
//  and a watch can sit on last month's build for weeks. A renamed key there is
//  not a re-render, it is a walk that does not arrive.
//
//  Every optional below is populated and every array holds an element, for the
//  reason `PayloadShapeFixture` gives: a `nil` optional is encoded as no key at
//  all, so a shape taken from a convenient fixture would be missing exactly
//  the keys most likely to be renamed unnoticed.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch payload shape")
struct WatchPayloadShapeTests {
    @Test("the trail package's wire shape is unchanged")
    func trailPackageShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.trailPackage,
            named: "WatchTrailPackage",
            versionedBy: "WatchTrailPackage.currentSchemaVersion",
            matches: [
                "elevationGainMeters: number",
                "elevationLossMeters: number",
                "hikeID: string",
                "points[].elevationMeters: number",
                "points[].latitude: number",
                "points[].longitude: number",
                "schemaVersion: number",
                "sentAt: number",
                "tintHex: string",
                "title: string",
                "totalDistanceMeters: number",
            ]
        )
    }

    @Test("the trail request's wire shape is unchanged")
    func trailRequestShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.trailRequest,
            named: "WatchTrailRequest",
            versionedBy: "WatchTrailRequest.currentSchemaVersion",
            matches: ["hikeID: string", "schemaVersion: number"]
        )
    }

    @Test("the library digest's wire shape is unchanged")
    func libraryDigestShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.libraryDigest,
            named: "WatchLibraryDigest",
            versionedBy: "WatchLibraryDigest.currentSchemaVersion",
            matches: [
                "hikes[].date: number",
                "hikes[].distanceMeters: number",
                "hikes[].durationSeconds: number",
                "hikes[].id: string",
                "hikes[].name: string",
                "schemaVersion: number",
                "sentAt: number",
            ]
        )
    }

    @Test("the recorded walk's wire shape is unchanged")
    func recordedWalkShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.recordedWalk,
            named: "WatchRecordedWalk",
            versionedBy: "WatchRecordedWalk.currentSchemaVersion",
            matches: [
                "activeSeconds: number",
                "distanceMeters: number",
                "elevationGainMeters: number",
                "elevationLossMeters: number",
                "endedAt: number",
                "fixes[].elevationMeters: number",
                "fixes[].horizontalAccuracy: number",
                "fixes[].latitude: number",
                "fixes[].longitude: number",
                "fixes[].resumesAfterPause: bool",
                "fixes[].timestamp: number",
                "schemaVersion: number",
                "sessionID: string",
                "startedAt: number",
                "title: string",
                "trailHikeID: string",
            ]
        )
    }

    @Test("the phone recording's wire shape is unchanged")
    func phoneRecordingShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.phoneRecording,
            named: "WatchPhoneRecording",
            versionedBy: "WatchPhoneRecording.currentSchemaVersion",
            matches: [
                "distanceMeters: number",
                "elapsedSeconds: number",
                "isTrailNameStale: bool",
                "schemaVersion: number",
                "state: string",
                "trailName: string",
                "updatedAt: number",
            ]
        )
    }

    @Test("the recording command's wire shape is unchanged")
    func recordingCommandShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.recordingCommand,
            named: "WatchRecordingCommand",
            versionedBy: "WatchRecordingCommand.currentSchemaVersion",
            matches: ["action: string", "id: string", "schemaVersion: number"]
        )
    }

    @Test("the command outcome's wire shape is unchanged")
    func commandOutcomeShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.commandOutcome,
            named: "WatchCommandOutcome",
            versionedBy: "WatchCommandOutcome.currentSchemaVersion",
            matches: [
                "commandID: string",
                "recording.distanceMeters: number",
                "recording.elapsedSeconds: number",
                "recording.isTrailNameStale: bool",
                "recording.schemaVersion: number",
                "recording.state: string",
                "recording.trailName: string",
                "recording.updatedAt: number",
                "refusal: string",
                "schemaVersion: number",
            ]
        )
    }

    @Test("the walk receipt's wire shape is unchanged")
    func walkReceiptShapeIsUnchanged() throws {
        try expectShape(
            of: Fixture.walkReceipt,
            named: "WatchWalkReceipt",
            versionedBy: "WatchWalkReceipt.currentSchemaVersion",
            matches: ["schemaVersion: number", "sessionID: string"]
        )
    }

    /// Guards the guard, the same way `everyStoredPropertyIsInTheShape` does
    /// next door: a property added to one of these types and left `nil` in the
    /// fixture is absent from both the shape and the expectation above, and
    /// the two agree about a key nothing checks.
    @Test(
        "every stored property reaches the encoded shape",
        arguments: Fixture.everyPayload
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

            Populate them in WatchPayloadShapeTests.Fixture and add them to the \
            expected shape above. A key that crosses this link untested is a key \
            a watch on an older build can silently stop understanding.
            """)
        )
    }

    /// Every kind has a pair of functions, and a kind that does not is
    /// unsendable — which would be silent rather than a compile failure, since
    /// nothing forces the extension to be exhaustive.
    @Test("every message kind can be written and read", arguments: WatchMessageKind.allCases)
    func everyKindHasItsPair(kind: WatchMessageKind) throws {
        let message: [String: Any] = switch kind {
        case .libraryDigest: try WatchLink.message(Fixture.libraryDigest)
        case .trailRequest: try WatchLink.message(Fixture.trailRequest)
        case .trailPackage: try WatchLink.message(Fixture.trailPackage)
        case .recordedWalk: try WatchLink.message(Fixture.recordedWalk)
        case .walkReceipt: try WatchLink.message(Fixture.walkReceipt)
        case .phoneRecording: try WatchLink.message(Fixture.phoneRecording)
        case .recordingCommand: try WatchLink.message(Fixture.recordingCommand)
        case .commandOutcome: try WatchLink.message(Fixture.commandOutcome)
        }
        #expect(WatchLink.kind(of: message) == kind)
    }

    enum Fixture {
        static let hikeID = UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID()
        static let sessionID = UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID()
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        static let everyPayload: [PayloadShapeFixture.Named] = [
            PayloadShapeFixture.Named(name: "WatchTrailPackage", value: trailPackage),
            PayloadShapeFixture.Named(name: "WatchTrailRequest", value: trailRequest),
            PayloadShapeFixture.Named(name: "WatchLibraryDigest", value: libraryDigest),
            PayloadShapeFixture.Named(name: "WatchRecordedWalk", value: recordedWalk),
            PayloadShapeFixture.Named(name: "WatchWalkReceipt", value: walkReceipt),
            PayloadShapeFixture.Named(name: "WatchPhoneRecording", value: phoneRecording),
            PayloadShapeFixture.Named(name: "WatchRecordingCommand", value: recordingCommand),
            PayloadShapeFixture.Named(name: "WatchCommandOutcome", value: commandOutcome),
        ]

        static let trailPackage = WatchTrailPackage(
            hikeID: hikeID,
            title: "Thumsee Loop",
            tintHex: "#2E7D32",
            totalDistanceMeters: 8420.5,
            points: [
                WatchTrailPoint(latitude: 47.6961, longitude: 12.8543, elevationMeters: 610.5),
                WatchTrailPoint(latitude: 47.6972, longitude: 12.8559, elevationMeters: 618.5),
            ],
            elevationGainMeters: 512.5,
            elevationLossMeters: 498.5,
            sentAt: stamp
        )

        static let trailRequest = WatchTrailRequest(hikeID: hikeID)

        static let libraryDigest = WatchLibraryDigest(
            hikes: [
                SharedHikeSummary(
                    id: hikeID,
                    name: "Thumsee Loop",
                    date: stamp,
                    distanceMeters: 8420.5,
                    durationSeconds: 9450.5
                ),
            ],
            sentAt: stamp
        )

        static let recordedWalk = WatchRecordedWalk(
            sessionID: sessionID,
            startedAt: stamp,
            endedAt: stamp.addingTimeInterval(9450.5),
            distanceMeters: 8420.5,
            activeSeconds: 9100.5,
            fixes: [
                WatchRecordedFix(
                    latitude: 47.6961,
                    longitude: 12.8543,
                    timestamp: stamp,
                    horizontalAccuracy: 6.5,
                    elevationMeters: 610.5,
                    resumesAfterPause: false
                ),
                WatchRecordedFix(
                    latitude: 47.6972,
                    longitude: 12.8559,
                    timestamp: stamp.addingTimeInterval(30),
                    horizontalAccuracy: 7.5,
                    elevationMeters: 618.5,
                    resumesAfterPause: true
                ),
            ],
            trailHikeID: hikeID,
            title: "Thumsee Loop",
            elevationGainMeters: 512.5,
            elevationLossMeters: 498.5
        )

        static let walkReceipt = WatchWalkReceipt(sessionID: sessionID)

        static let phoneRecording = WatchPhoneRecording(
            state: .recording,
            elapsedSeconds: 9100.5,
            distanceMeters: 8420.5,
            trailName: "Thumsee Loop",
            isTrailNameStale: true,
            updatedAt: stamp.addingTimeInterval(9450.5)
        )

        static let recordingCommand = WatchRecordingCommand(action: .pause, id: commandID)

        static let commandOutcome = WatchCommandOutcome(
            commandID: commandID,
            recording: phoneRecording,
            refusal: "That hike isn't running."
        )

        static let commandID = UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID()
    }
}

// swiftlint:enable no_magic_numbers
