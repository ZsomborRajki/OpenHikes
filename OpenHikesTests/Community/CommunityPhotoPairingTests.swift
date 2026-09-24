//
//  CommunityPhotoPairingTests.swift
//  OpenHikesTests
//
//  Which pin belongs to which downloaded photograph.
//
//  Every picture in a published hike is supposed to sit on the map where it
//  was taken — that is the reason for carrying photographs with a shared trail
//  at all. The upload keeps that true by appending a pin only alongside a file
//  that exported, so the two arrays describe each other by index. The download
//  has to keep the same promise across an asset CloudKit could not hand back,
//  and the index is the only thing that can: a survivor knows which pin was
//  written for it however many of its neighbours went missing.
//
//  `CKRecord`-free on purpose. What is worth pinning is the pairing, and the
//  fetch around it needs the public database and an asset CloudKit actually
//  stored — see *the tests that never reach the real transport* in the
//  instructions.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community photo pairing")
struct CommunityPhotoPairingTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let pinCount = 4

    /// A pin per photograph, each at its own place and its own minute, so a
    /// pin that ended up on the wrong photograph is visible in the assertion
    /// rather than merely possible.
    private static func pins(_ count: Int = pinCount) -> [CommunityPhotoPin] {
        (0..<count).map { index in
            CommunityPhotoPin(
                capturedAt: hikeDate.addingTimeInterval(Double(index) * 60),
                coordinate: CLLocationCoordinate2D(
                    latitude: 47.6 + Double(index) / 100,
                    longitude: 12.8 + Double(index) / 100
                )
            )
        }
    }

    /// The files that arrived, named after the asset each came from.
    private static func downloaded(_ indices: [Int]) -> [(index: Int, url: URL)] {
        indices.map { ($0, URL(fileURLWithPath: "/tmp/photo-\($0).jpeg")) }
    }

    @Test("nothing lost keeps every pin where it was")
    func allArrivingKeepsEveryPin() {
        let paired = CloudKitCommunityTransport.pins(
            Self.pins(),
            for: Self.downloaded([0, 1, 2, 3]),
            of: Self.pinCount,
            takenOn: Self.hikeDate
        )

        #expect(paired == Self.pins())
    }

    /// The failure this suite exists for: one asset out of the middle used to
    /// cost every other photograph its location and its capture time.
    @Test("an asset lost in the middle costs only its own pin")
    func aLostAssetCostsOnlyItsOwnPin() {
        let all = Self.pins()

        let paired = CloudKitCommunityTransport.pins(
            all,
            for: Self.downloaded([0, 1, 3]),
            of: Self.pinCount,
            takenOn: Self.hikeDate
        )

        #expect(paired == [all[0], all[1], all[3]])
    }

    /// The first one is the case a shorter array silently gets right for the
    /// wrong reason — everything shifts up by one and still reads as pinned.
    @Test("the first asset failing does not shift the rest up")
    func theFirstAssetFailingDoesNotShiftTheRest() {
        let all = Self.pins()

        let paired = CloudKitCommunityTransport.pins(
            all,
            for: Self.downloaded([1, 2, 3]),
            of: Self.pinCount,
            takenOn: Self.hikeDate
        )

        #expect(paired == [all[1], all[2], all[3]])
        #expect(paired.first?.coordinate?.latitude == all[1].coordinate?.latitude)
    }

    @Test("every asset failing leaves nothing to pin")
    func everyAssetFailingLeavesNothing() {
        let paired = CloudKitCommunityTransport.pins(
            Self.pins(),
            for: [],
            of: Self.pinCount,
            takenOn: Self.hikeDate
        )

        #expect(paired.isEmpty)
    }

    /// A record whose two arrays genuinely disagree is a reviewer having
    /// edited one of them by hand. The index means nothing there, so the lot
    /// still goes — a photograph at another photograph's coordinate is the
    /// failure nothing downstream could notice.
    @Test("a record whose pins and assets disagree still drops the lot")
    func aGenuineMismatchStillDropsThePins() {
        let paired = CloudKitCommunityTransport.pins(
            Self.pins(2),
            for: Self.downloaded([0, 1, 2, 3]),
            of: Self.pinCount,
            takenOn: Self.hikeDate
        )

        #expect(paired.count == 4)
        #expect(paired.allSatisfy { $0.coordinate == nil })
        #expect(paired.allSatisfy { $0.capturedAt == Self.hikeDate })
    }
}
