//
//  CommunityPhotoOrderTests.swift
//  OpenHikesTests
//
//  The order a hiker's own photographs are offered in and sent in, asked of
//  both places that read it: the strip both send forms draw
//  (``CommunityPublisher/shareablePhotos(of:)``) and the list both uploads
//  take (``CommunityPublisher/selectedPhotos(from:excluding:onThisDevice:)``).
//
//  The rule is anchored photographs first, each half in the order it was
//  taken, with a tie broken the way ``Hike/orderedPhotos`` breaks one. It is
//  written once, in the strip's list, and the upload's list is that one less
//  what was struck off and cut at the cap (#1001). Every assertion here was
//  first run against the code from before that, when each list spelled the
//  rule out for itself, and passed there: the suite pins behaviour that did
//  not change rather than a fix.
//
//  Each test names the order it expects outright and asks both lists for it,
//  rather than comparing one list with the other. Two readings of a rule
//  agreeing with each other is not the claim; both agreeing with the rule is.
//
//  The rows carry no pixels, because the order is settled on the rows before
//  anything touches the disk — except in the last two tests, which follow it
//  into a real draft from each publisher, identified by the minute each
//  picture was taken because a pin's `capturedAt` is what survives the trip.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community photo order")
struct CommunityPhotoOrderTests {
    private static let firstCapture: TimeInterval = 1_700_000_000
    private static let trailSpot = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
    private static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Almbachklamm",
        authorName: "Anna"
    )

    /// When the photograph of `minute` was taken, spelled once so a fixture
    /// and an assertion cannot drift apart.
    private static func capturedAt(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: firstCapture + Double(minute) * 60)
    }

    /// A row of the hiker's own with no file behind it.
    private static func photo(minute: Int, anchored: Bool, id: UUID = UUID()) -> HikePhoto {
        HikePhoto(
            id: id,
            capturedAt: capturedAt(minute),
            coordinate: anchored ? trailSpot : nil
        )
    }

    private static func strip(of hike: Hike) -> [UUID] {
        CommunityPublisher.shareablePhotos(of: hike).map(\.id)
    }

    private static func upload(of hike: Hike, excluding excluded: Set<UUID> = []) -> [UUID] {
        // Every row taken to have its file here, because the order is what is
        // asked and these rows carry no pixels — which rows have files is
        // `CommunitySharePhotoCountTests`'s question.
        let selected = CommunityPublisher.selectedPhotos(
            from: CommunityPublisher.shareablePhotos(of: hike),
            excluding: excluded,
            onThisDevice: Set(hike.photos.map(\.id))
        )
        return selected.map(\.id)
    }

    /// Attaches a photograph whose pixels really are on this device for each
    /// minute, anchored or not, so a draft can carry it.
    private func addStoredPhotos(
        _ minutes: [(minute: Int, anchored: Bool)],
        to hike: Hike,
        in sandbox: PhotoStoreSandbox
    ) async {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        for entry in minutes {
            let captured = Self.capturedAt(entry.minute)
            let coordinate = entry.anchored ? Self.trailSpot : nil
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(data, capturedAt: captured, coordinate: coordinate)
            }).value else { continue }
            hike.photos.append(photo)
        }
    }

    @Test("anchored photographs come first, each half in the order it was taken")
    func anchoredFirstThenUnanchored() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let early = Self.photo(minute: 0, anchored: false)
        let first = Self.photo(minute: 1, anchored: true)
        let late = Self.photo(minute: 2, anchored: false)
        let second = Self.photo(minute: 3, anchored: true)
        // Stored out of order, so what is asserted is the rule's order and
        // not the array's.
        hike.photos = [second, late, early, first]

        let expected = [first, second, early, late].map(\.id)
        #expect(Self.strip(of: hike) == expected, "the strip")
        #expect(Self.upload(of: hike) == expected, "the upload")
    }

    @Test("two photographs taken in the same second go in identifier order")
    func aTieIsBrokenByIdentifier() throws {
        let ids = try (1...4).map { digit in
            try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(digit)"))
        }
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let anchoredLow = Self.photo(minute: 1, anchored: true, id: ids[0])
        let anchoredHigh = Self.photo(minute: 1, anchored: true, id: ids[1])
        let unanchoredLow = Self.photo(minute: 0, anchored: false, id: ids[2])
        let unanchoredHigh = Self.photo(minute: 0, anchored: false, id: ids[3])
        hike.photos = [unanchoredHigh, anchoredHigh, unanchoredLow, anchoredLow]

        #expect(Self.strip(of: hike) == ids, "the strip")
        #expect(Self.upload(of: hike) == ids, "the upload")
    }

    @Test("a photograph somebody else took, or a place with no picture, is in neither list")
    func onlyTheHikersOwnAreOrdered() throws {
        let page = try #require(URL(string: "https://commons.wikimedia.org/wiki/File:Gorge.jpg"))
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let ownUnanchored = Self.photo(minute: 0, anchored: false)
        let imported = HikePhoto(
            capturedAt: Self.capturedAt(1),
            coordinate: Self.trailSpot,
            importedFromListingID: "listing-1"
        )
        let licensed = HikePhoto(
            capturedAt: Self.capturedAt(2),
            coordinate: Self.trailSpot,
            license: HikePhotoLicense(name: "CC0", url: nil, sourceURL: page)
        )
        let own = Self.photo(minute: 3, anchored: true)
        let placeOnly = HikePhoto(
            capturedAt: Self.capturedAt(4),
            coordinate: Self.trailSpot,
            isPlaceOnly: true
        )
        hike.photos = [placeOnly, licensed, own, imported, ownUnanchored]

        let expected = [own.id, ownUnanchored.id]
        #expect(Self.strip(of: hike) == expected, "the strip")
        #expect(Self.upload(of: hike) == expected, "the upload")
    }

    /// More photographs than the cap, with the two unanchored ones taken
    /// before any of the rest. They are what the cap leaves behind, because
    /// the order is settled before the cap is applied.
    @Test("the cap falls on the unanchored end of the strip")
    func theCapLeavesTheUnanchoredBehind() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let unanchored = (0..<2).map { Self.photo(minute: $0, anchored: false) }
        let anchored = (0..<CommunityPublisher.maximumPhotos).map { index in
            Self.photo(minute: 2 + index, anchored: true)
        }
        hike.photos = unanchored + anchored

        #expect(Self.strip(of: hike) == (anchored + unanchored).map(\.id), "the strip")
        #expect(Self.upload(of: hike) == anchored.map(\.id), "the upload")
    }

    /// A full set of anchored photographs, one of somebody else's next by the
    /// clock, then two unanchored ones of the hiker's own. Striking off the
    /// first must hand its place to the first *own* photograph past the cap,
    /// which is the unanchored one: the imported row is never a candidate.
    @Test("striking one off lets the next of the hiker's own in")
    func anExclusionLetsTheNextOwnPhotographIn() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let cap = CommunityPublisher.maximumPhotos
        let anchored = (0..<cap).map { Self.photo(minute: $0, anchored: true) }
        let imported = HikePhoto(
            capturedAt: Self.capturedAt(cap),
            coordinate: Self.trailSpot,
            importedFromListingID: "listing-1"
        )
        let unanchored = (0..<2).map { Self.photo(minute: cap + 1 + $0, anchored: false) }
        hike.photos = anchored + [imported] + unanchored

        let upload = Self.upload(of: hike, excluding: [anchored[0].id])

        #expect(upload == (anchored.dropFirst() + [unanchored[0]]).map(\.id))
        #expect(upload.count == cap, "a full upload, not one short")
        #expect(
            Self.strip(of: hike) == (anchored + unanchored).map(\.id),
            "the strip still draws the struck-off one, so it can be put back"
        )
    }

    @Test("a shared hike's draft carries its photographs in that order")
    func theShareDraftKeepsTheOrder() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(
            [(3, true), (0, false), (2, false), (1, true)],
            to: hike,
            in: sandbox
        )
        let transport = StubCommunityTransport()

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let draft = try #require(transport.recording.submissions.first)
        #expect(draft.photoPins.map(\.capturedAt) == [1, 3, 0, 2].map(Self.capturedAt))
    }

    @Test("a contribution's draft carries its photographs in that order")
    func theContributionDraftKeepsTheOrder() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(
            [(3, true), (0, false), (2, false), (1, true)],
            to: hike,
            in: sandbox
        )
        let transport = StubCommunityTransport()

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let draft = try #require(transport.recording.photoDrafts.first)
        #expect(draft.photoPins.map(\.capturedAt) == [1, 3, 0, 2].map(Self.capturedAt))
    }
}
