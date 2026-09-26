//
//  WatchTrailRevisionTests.swift
//  OpenHikesSharedTests
//
//  The watch asking again for a trail it already holds, and the phone saying
//  nothing unless the route has changed — issue #694. The watch has no test
//  bundle, so the whole policy is here: ``WatchModel`` only builds the request
//  and the phone only asks it ``WatchTrailRequest/needs(_:)``.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch trail revision")
struct WatchTrailRevisionTests {
    @Test("the same trail packaged twice is the same revision")
    func repackagingKeepsTheRevision() {
        let later = Fixture.package(sentAt: Fixture.stamp.addingTimeInterval(3600))

        #expect(Fixture.package().revision == later.revision)
    }

    @Test("the revision survives the link and the watch's disk")
    func revisionSurvivesEncoding() throws {
        let package = Fixture.package()
        let crossed = try WatchLink.trailPackage(from: WatchLink.message(package))

        #expect(crossed.revision == package.revision)
    }

    @Test(
        "an edit the watch would draw, match or name is a new revision",
        arguments: Fixture.Edit.allCases
    )
    func everyEditChangesTheRevision(edit: Fixture.Edit) {
        #expect(Fixture.package(edit).revision != Fixture.package().revision)
    }

    @Test("a watch holding this trail names its revision")
    func heldTrailIsNamed() {
        let held = Fixture.package()
        let request = WatchTrailRequest(hikeID: Fixture.hikeID, holding: held)

        #expect(request.heldRevision == held.revision)
    }

    @Test("a watch holding another trail, or none, names nothing")
    func otherTrailIsNotNamed() {
        let other = WatchTrailRequest(hikeID: UUID(), holding: Fixture.package())
        let none = WatchTrailRequest(hikeID: Fixture.hikeID, holding: nil)

        #expect(other.heldRevision == nil)
        #expect(none.heldRevision == nil)
    }

    @Test("an unchanged trail is not sent again")
    func unchangedTrailIsNotNeeded() {
        let request = WatchTrailRequest(hikeID: Fixture.hikeID, holding: Fixture.package())

        #expect(!request.needs(Fixture.package(sentAt: .now)))
    }

    @Test("an edited trail is sent, and so is one the watch does not hold")
    func editedOrMissingTrailIsNeeded() {
        let holding = WatchTrailRequest(hikeID: Fixture.hikeID, holding: Fixture.package())
        let empty = WatchTrailRequest(hikeID: Fixture.hikeID, holding: nil)

        #expect(holding.needs(Fixture.package(.movedPoint)))
        #expect(empty.needs(Fixture.package()))
    }

    @Test("a request from a watch that names no revision still reads")
    func requestWithoutRevisionDecodes() throws {
        // A watch build from before the field existed, written by hand for the
        // same reason `WatchLinkTests` writes its future-version body by hand.
        let body = Data(#"{"schemaVersion":1,"hikeID":"\#(Fixture.hikeID.uuidString)"}"#.utf8)
        let request = try WatchLink.trailRequest(from: ["kind": "trailRequest", "body": body])

        #expect(request.heldRevision == nil)
        #expect(request.needs(Fixture.package()))
    }

    enum Fixture {
        static let hikeID = UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID()
        static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        enum Edit: CaseIterable, Sendable {
            case movedPoint, addedPoint, droppedElevation, renamed, retinted, relengthened, regained
        }

        static func package(_ edit: Edit? = nil, sentAt: Date = stamp) -> WatchTrailPackage {
            var package = WatchTrailPackage(
                hikeID: hikeID,
                title: "Thumsee Loop",
                tintHex: "#2E7D32",
                totalDistanceMeters: 8420.5,
                points: [
                    WatchTrailPoint(latitude: 47.6961, longitude: 12.8543, elevationMeters: 610.5),
                    WatchTrailPoint(latitude: 47.6972, longitude: 12.8559, elevationMeters: 618.5),
                    WatchTrailPoint(latitude: 47.6989, longitude: 12.8571, elevationMeters: 624.25),
                ],
                elevationGainMeters: 512.5,
                elevationLossMeters: 498.5,
                sentAt: sentAt
            )
            switch edit {
            case .movedPoint: package.points[1].longitude += 0.0004
            case .addedPoint: package.points.append(WatchTrailPoint(latitude: 47.7, longitude: 12.858))
            case .droppedElevation: package.points[2].elevationMeters = nil
            case .renamed: package.title = "Thumsee and Back"
            case .retinted: package.tintHex = "#1565C0"
            case .relengthened: package.totalDistanceMeters += 120
            case .regained: package.elevationGainMeters = nil
            case nil: break
            }
            return package
        }
    }
}

// swiftlint:enable no_magic_numbers
