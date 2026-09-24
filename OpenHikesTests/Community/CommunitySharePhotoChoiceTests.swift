//
//  CommunitySharePhotoChoiceTests.swift
//  OpenHikesTests
//
//  Which photographs a share actually carries once the hiker has struck some
//  off, and the one thing about that which is easy to get quietly wrong.
//
//  The obvious half is that an excluded picture must not reach the upload, and
//  it is asserted below against a real draft rather than against the function
//  that built it — the same rule `CommunitySharePhotoCountTests` follows next
//  door, because agreeing with the code under test is not the claim.
//
//  The half worth the suite is the **order of the two operations**.
//  ``CommunityPublisher/maximumPhotos`` caps a submission, and a hiker with
//  more pictures than that who strikes one off is choosing *which* of them go
//  — so the exclusion has to be applied *before* the cap. Filtering afterwards
//  compiles, passes any test that stays under the cap, and turns "leave that
//  one out" into "send one fewer": the first picture past the cap stays
//  outside it and the walk quietly loses a slot. That is the assertion this
//  file exists for.
//
//  Written against the constant throughout and never against its value, which
//  is what lets the cap move — it has, from twelve to thirty-six — without a
//  suite that reads as being about a number it no longer is.
//
//  Photographs are identified in the draft by the minute they were taken,
//  because that is what survives the trip: the upload carries
//  ``CommunityPhotoPin``s rather than rows, and a pin's `capturedAt` is the
//  only field a test can tie back to the picture it came from.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community share photo choice")
struct CommunitySharePhotoChoiceTests {
    private static let firstCapture: TimeInterval = 1_700_000_000
    private static let captureGap: TimeInterval = 60

    /// When photograph `index` was taken, spelled once so an assertion and a
    /// fixture cannot drift apart.
    private static func capturedAt(_ index: Int) -> Date {
        Date(timeIntervalSince1970: firstCapture + Double(index) * captureGap)
    }

    /// Attaches `count` photographs whose pixels really are on this device,
    /// each a minute after the last so the draft can be read back by time.
    private func addStoredPhotos(
        _ count: Int,
        to hike: Hike,
        in sandbox: PhotoStoreSandbox
    ) async -> [HikePhoto] {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        var added: [HikePhoto] = []
        for index in 0..<count {
            let captured = Self.capturedAt(index)
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(
                    data,
                    capturedAt: captured,
                    coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
                )
            }).value else { continue }
            hike.photos.append(photo)
            added.append(photo)
        }
        return added
    }

    /// Shares `hike` with `excluded` struck off, and hands back what the
    /// upload took.
    private func share(
        _ hike: Hike,
        excluding excluded: Set<UUID>,
        in sandbox: PhotoStoreSandbox
    ) async throws -> CommunitySubmissionDraft {
        let transport = StubCommunityTransport()
        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport,
            excludingPhotos: excluded,
            store: sandbox.store
        )
        #expect(outcome == .submitted)
        return try #require(transport.recording.submissions.first)
    }

    @Test("a photograph struck off the strip does not go")
    func anExcludedPhotographIsNotUploaded() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let photos = await addStoredPhotos(3, to: hike, in: sandbox)

        let draft = try await share(hike, excluding: [photos[1].id], in: sandbox)

        #expect(draft.photoFileURLs.count == 2)
        #expect(draft.photoPins.count == 2)
        #expect(
            draft.photoPins.map(\.capturedAt) == [Self.capturedAt(0), Self.capturedAt(2)],
            "the two that were left ticked, in the order they were walked"
        )
    }

    /// The claim the cap makes this suite necessary for.
    ///
    /// Thirteen photographs and a cap of twelve: striking the first off must
    /// let the thirteenth in, leaving a full twelve. An exclusion applied
    /// after the cap would send eleven and never mention it.
    @Test("striking one off lets the next one in, rather than sending one fewer")
    func exclusionIsAppliedBeforeTheCap() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let overCap = CommunityPublisher.maximumPhotos + 1
        let photos = await addStoredPhotos(overCap, to: hike, in: sandbox)

        let draft = try await share(hike, excluding: [photos[0].id], in: sandbox)

        #expect(
            draft.photoFileURLs.count == CommunityPublisher.maximumPhotos,
            "a full submission, not one short"
        )
        let taken = Set(draft.photoPins.map(\.capturedAt))
        #expect(!taken.contains(Self.capturedAt(0)), "the one struck off stayed behind")
        #expect(
            taken.contains(Self.capturedAt(overCap - 1)),
            "and the one that had been over the cap came in"
        )
    }

    /// What the form says, against what the upload does, with a picture struck
    /// off — the question `CommunitySharePhotoCountTests` asks of the ordinary
    /// case, asked again of this one.
    @Test("the number under the strip is the number that goes")
    func theFormsCountMatchesTheUpload() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let photos = await addStoredPhotos(4, to: hike, in: sandbox)
        let excluded: Set<UUID> = [photos[0].id, photos[3].id]

        let formCount = await CommunityPublisher.sendablePhotoCount(
            of: hike,
            excludingPhotos: excluded,
            store: sandbox.store
        )
        let draft = try await share(hike, excluding: excluded, in: sandbox)

        #expect(formCount == draft.photoFileURLs.count)
        #expect(formCount == 2)
    }

    @Test("striking every photograph off shares none of them")
    func excludingEverythingSendsNoPhotographs() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let photos = await addStoredPhotos(3, to: hike, in: sandbox)

        let draft = try await share(hike, excluding: Set(photos.map(\.id)), in: sandbox)

        #expect(draft.photoFileURLs.isEmpty)
        #expect(draft.photoPins.isEmpty)
        // And the walk still goes: striking off every picture is a decision
        // about the pictures, not a refusal to share the hike.
        #expect(!draft.route.isEmpty)
    }

    /// The default, which is what almost every share is: nothing struck off
    /// sends everything, exactly as it did before the strip could be tapped.
    @Test("an untouched strip sends every photograph")
    func anUntouchedStripIsUnchanged() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        _ = await addStoredPhotos(3, to: hike, in: sandbox)

        let draft = try await share(hike, excluding: [], in: sandbox)

        #expect(draft.photoFileURLs.count == 3)
    }

    /// The strip draws every photograph, including the struck-off ones — they
    /// have to stay on screen to be put back — and in the order the upload
    /// will take them, so the twelve that fit are the first twelve drawn.
    @Test("the strip offers every photograph, in the order the upload takes them")
    func theStripOffersEverythingInUploadOrder() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let photos = await addStoredPhotos(3, to: hike, in: sandbox)

        let offered = CommunityPublisher.shareablePhotos(of: hike)

        #expect(offered.map(\.id) == photos.map(\.id))
        #expect(
            CommunityPublisher.shareablePhotos(of: hike).count == hike.photos.count,
            "a struck-off picture is still drawn, or there would be no way back"
        )
    }
}
