//
//  WatchStoredFileTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch stored files")
struct WatchStoredFileTests {
    @Test("The library and the trail read back exactly as they were written")
    func currentFormatRoundTrips() throws {
        let digest = WatchLibraryDigest(hikes: [Fixture.summary], sentAt: Fixture.stamp)
        #expect(try WatchStoredFile.libraryDigest(from: JSONEncoder().encode(digest)) == digest)

        let package = Fixture.package
        #expect(try WatchStoredFile.trailPackage(from: JSONEncoder().encode(package)) == package)
    }

    @Test("A library in an older or newer format is refused", arguments: [-1, 1, 998])
    func libraryInAnotherFormatIsRefused(offset: Int) throws {
        let supported = WatchLibraryDigest.currentSchemaVersion
        let data = try Fixture.rewritten(
            WatchLibraryDigest(hikes: [Fixture.summary], sentAt: Fixture.stamp),
            toVersion: supported + offset
        )
        #expect(throws: SharedPayloadReadFailure.unsupportedVersion(found: supported + offset, supported: supported)) {
            try WatchStoredFile.libraryDigest(from: data)
        }
    }

    @Test("A trail in an older or newer format is refused", arguments: [-1, 1, 998])
    func trailInAnotherFormatIsRefused(offset: Int) throws {
        let supported = WatchTrailPackage.currentSchemaVersion
        let data = try Fixture.rewritten(Fixture.package, toVersion: supported + offset)
        #expect(throws: SharedPayloadReadFailure.unsupportedVersion(found: supported + offset, supported: supported)) {
            try WatchStoredFile.trailPackage(from: data)
        }
    }

    @Test("The current format in the wrong shape is refused as malformed")
    func malformedFileIsRefused() throws {
        let data = Data(#"{"schemaVersion":\#(WatchTrailPackage.currentSchemaVersion)}"#.utf8)
        #expect {
            try WatchStoredFile.trailPackage(from: data)
        } throws: { error in
            guard case .malformed = error as? SharedPayloadReadFailure else { return false }
            return true
        }
    }

    private enum Fixture {
        static let hikeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
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

        /// Every field intact and only the version changed: the file a build
        /// on the other side of a format change would have left.
        static func rewritten(_ value: some Encodable, toVersion version: Int) throws -> Data {
            let encoded = try JSONEncoder().encode(value)
            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["schemaVersion"] = version
            return try JSONSerialization.data(withJSONObject: object)
        }
    }
}
