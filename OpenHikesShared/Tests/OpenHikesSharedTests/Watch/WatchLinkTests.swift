//
//  WatchLinkTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch link envelope")
struct WatchLinkTests {
    @Test("Every kind round-trips through its own pair of functions")
    func everyKindRoundTrips() throws {
        let digest = WatchLibraryDigest(hikes: [Fixture.summary])
        #expect(try WatchLink.libraryDigest(from: WatchLink.message(digest)) == digest)

        let request = WatchTrailRequest(hikeID: Fixture.hikeID)
        #expect(try WatchLink.trailRequest(from: WatchLink.message(request)) == request)

        let package = Fixture.package
        #expect(try WatchLink.trailPackage(from: WatchLink.message(package)) == package)

        let walk = try #require(Fixture.walk)
        #expect(try WatchLink.recordedWalk(from: WatchLink.message(walk)) == walk)

        let receipt = WatchWalkReceipt(sessionID: Fixture.sessionID)
        #expect(try WatchLink.walkReceipt(from: WatchLink.message(receipt)) == receipt)
    }

    @Test("A message names its kind without its body being read")
    func kindIsReadableAlone() throws {
        let message = try WatchLink.message(WatchTrailRequest(hikeID: Fixture.hikeID))
        #expect(WatchLink.kind(of: message) == .trailRequest)
    }

    @Test("A kind this build does not know reads as no kind rather than throwing")
    func unknownKindIsNotAFailure() {
        #expect(WatchLink.kind(of: ["kind": "somethingLater", "body": Data()]) == nil)
        #expect(WatchLink.kind(of: [:]) == nil)
    }

    @Test("A body in a format this build does not read is refused whole")
    func futureSchemaVersionIsRefused() throws {
        // Written by hand rather than by bumping the type's own constant,
        // because what is being tested is a *newer watch* — a build that
        // cannot be compiled here — talking to this one.
        let body = Data(#"{"schemaVersion":99,"hikeID":"\#(Fixture.hikeID.uuidString)"}"#.utf8)
        #expect(throws: WatchLinkFailure.unsupportedVersion(.trailRequest, found: 99, supported: 1)) {
            try WatchLink.trailRequest(from: ["kind": "trailRequest", "body": body])
        }
    }

    @Test("A known kind with nothing in it is a failure that names the kind")
    func missingBodyNamesItsKind() {
        #expect(throws: WatchLinkFailure.missingBody(.trailPackage)) {
            try WatchLink.trailPackage(from: ["kind": "trailPackage"])
        }
    }

    @Test("The right format in the wrong shape is reported as malformed")
    func malformedBodyIsReported() throws {
        let body = Data(#"{"schemaVersion":1}"#.utf8)
        #expect(throws: WatchLinkFailure.self) {
            try WatchLink.trailRequest(from: ["kind": "trailRequest", "body": body])
        }
    }

    private enum Fixture {
        static let hikeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
        static let sessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        static let summary = SharedHikeSummary(
            id: hikeID,
            name: "Rinnkendlsteig",
            date: stamp,
            distanceMeters: 12_400,
            durationSeconds: 18_000
        )

        static let package = WatchTrailPackage(
            hikeID: hikeID,
            title: "Rinnkendlsteig",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 12_400,
            points: [
                WatchTrailPoint(latitude: 47.55, longitude: 12.98, elevationMeters: 610),
                WatchTrailPoint(latitude: 47.56, longitude: 12.99, elevationMeters: 980),
            ],
            elevationGainMeters: 470,
            sentAt: stamp
        )

        static var walk: WatchRecordedWalk? {
            var accumulator = WatchWalkAccumulator()
            accumulator.accept(
                latitude: 47.55,
                longitude: 12.98,
                timestamp: stamp,
                horizontalAccuracy: 8,
                elevationMeters: 610
            )
            accumulator.accept(
                latitude: 47.5504,
                longitude: 12.98,
                timestamp: stamp.addingTimeInterval(30),
                horizontalAccuracy: 8,
                elevationMeters: 618
            )
            return accumulator.recordedWalk(
                sessionID: sessionID,
                startedAt: stamp,
                endedAt: stamp.addingTimeInterval(30),
                trailHikeID: hikeID,
                title: "Rinnkendlsteig"
            )
        }
    }
}
