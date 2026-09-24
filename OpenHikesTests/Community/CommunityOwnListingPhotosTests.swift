//
//  CommunityOwnListingPhotosTests.swift
//  OpenHikesTests
//
//  Adding photographs to a hike this hiker has already published, without
//  publishing the hike a second time.
//
//  The bug this suite exists to keep fixed is a duplicate listing. A published
//  hike's only offer used to be *Share Again*, and a submission cannot be
//  amended — by ``CommunitySchema``'s design, since an amendable submission is
//  an approved record that can be swapped after approval — so the second share
//  made a second listing of the same walk and pointed the device at it. The
//  first stayed live, stayed findable, and was now the copy its own author
//  could no longer see. What the hiker had actually come back to do was add
//  the pictures they got off the camera afterwards.
//
//  So there are two contracts here, and they are different in kind.
//
//  **Where the photographs go.** A hike that is live is a target like any
//  other trail already in the list — see
//  ``CommunityPhotoTarget/published(listingID:title:)`` — and the thing that
//  makes it *not* like any other is that nobody else published it, which is
//  what ``CommunityPhotoTarget/isYours`` carries to the form.
//
//  **Which photographs go.** A picture that has already been uploaded must not
//  be uploaded again, because nothing can replace or withdraw the first copy:
//  a second send is a second copy in the same gallery, for good. That is what
//  ``HikePhoto/sentToCommunityAt`` records, and the stamp is deliberately put
//  on by *both* senders and only over the pictures whose files really left —
//  a row whose pixels are on another device is dropped by the encode, and
//  marking it sent would be the one error this stamp can make that costs a
//  hiker a photograph rather than a duplicate.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Photographs onto a hike of your own")
struct CommunityOwnListingPhotosTests {
    /// Attaches `count` photo rows whose pixels are really on this device.
    ///
    /// ``CommunityPhotoPublisherTests``'s helper, and the same one for the
    /// same reason: a row with a file behind it and a row without are the two
    /// cases every one of these assertions turns on.
    private func addStoredPhotos(
        _ count: Int,
        to hike: Hike,
        in sandbox: PhotoStoreSandbox
    ) async {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        for index in 0..<count {
            let captured = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(
                    data,
                    capturedAt: captured,
                    coordinate: CLLocationCoordinate2D(
                        latitude: 47.6 + Double(index) / 10_000,
                        longitude: 12.8
                    )
                )
            }).value else { continue }
            hike.photos.append(photo)
        }
    }

    // MARK: - Where they go

    @Test("a published hike is a target, and one the hiker owns")
    func aPublishedHikeIsItsOwnTarget() throws {
        let target = try #require(
            CommunityPhotoTarget.published(listingID: "listing-7", title: "Almbachklamm")
        )

        #expect(target.listingID == "listing-7")
        #expect(target.title == "Almbachklamm")
        #expect(target.isYours)
        // Nobody to credit: naming the hiker back to themselves would read as
        // a stranger on their own trail.
        #expect(target.authorName == nil)
        #expect(!target.isCurated)
    }

    @Test("a hike that is not live is not a target at all")
    func anUnpublishedHikeIsNotATarget() {
        // `nil` is ``Hike/communityListingID`` for every state but *published*
        // — never shared, waiting for review, and declined are one absence.
        #expect(CommunityPhotoTarget.published(listingID: nil, title: "Almbachklamm") == nil)
    }

    @Test("a retread of your own hike is yours too")
    func aRetreadTargetIsYours() async throws {
        let context = try Fixture.modelContext()
        let published = Fixture.hike(in: context, title: "Almbachklamm") { hike in
            hike.communitySubmissionID = "submission-1"
            hike.communityListingID = "listing-1"
        }
        let again = Fixture.hike(in: context, title: "Almbachklamm again", route: published.route)

        let eligibility = await CommunityPublishingCheck.eligibility(of: again, in: context)

        let target = try #require(eligibility.photoTarget)
        #expect(target.listingID == "listing-1")
        #expect(target.isYours)
    }

    // MARK: - Which of them go

    @Test("sharing a hike stamps the photographs that actually went")
    func sharingStampsWhatWent() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        await addStoredPhotos(2, to: hike, in: sandbox)
        // A third row whose pixels live on the device it was added on, which
        // is the ordinary state of a hike on a hiker's second device. It is
        // dropped by the encode, so it never leaves — and must not be marked
        // as though it had, or the hiker could never send it from here.
        let elsewhere = HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_500))
        hike.photos.append(elsewhere)

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Ada",
            transport: StubCommunityTransport(),
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let stamped = hike.photos.filter(\.hasBeenSentToCommunity).map(\.id)
        #expect(stamped.count == 2)
        #expect(!stamped.contains(elsewhere.id))
    }

    @Test("what the form leaves out is what has already gone")
    func theFormOpensOnWhatHasNotGone() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        await addStoredPhotos(2, to: hike, in: sandbox)

        _ = await CommunityPublisher.share(
            hike,
            authorName: "Ada",
            transport: StubCommunityTransport(),
            store: sandbox.store
        )
        // The photograph off the camera, added after the walk went live: the
        // whole reason a hiker comes back to a published hike. Identified by
        // what is new rather than by position — the helper hands every batch
        // the same capture times, so the newest row is not the last one in
        // ``Hike/orderedPhotos``.
        let before = Set(hike.photos.map(\.id))
        await addStoredPhotos(1, to: hike, in: sandbox)
        let added = try #require(hike.photos.first { !before.contains($0.id) })

        let excluded = CommunityPublisher.alreadySentPhotoIDs(of: hike)

        #expect(excluded.count == 2)
        #expect(!excluded.contains(added.id))
        #expect(CommunityPublisher.selectedPhotos(of: hike, excluding: excluded) == [added])
    }

    @Test("a top-up carries the new photograph and not the published one")
    func aTopUpSendsOnlyWhatIsNew() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()

        _ = await CommunityPublisher.share(
            hike,
            authorName: "Ada",
            transport: transport,
            store: sandbox.store
        )
        hike.communityListingID = "listing-1"
        await addStoredPhotos(1, to: hike, in: sandbox)

        let target = try #require(
            CommunityPhotoTarget.published(
                listingID: hike.communityListingID,
                title: hike.displayTitle
            )
        )
        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: target,
            authorName: "Ada",
            transport: transport,
            excludingPhotos: CommunityPublisher.alreadySentPhotoIDs(of: hike),
            store: sandbox.store
        )

        #expect(outcome == .submitted)
        let draft = try #require(transport.recording.photoDrafts.first)
        // One picture, onto the listing that already exists. The hike itself
        // was submitted exactly once.
        #expect(draft.photoFileURLs.count == 1)
        #expect(draft.target.listingID == "listing-1")
        #expect(transport.recording.submissions.count == 1)
        // And now all three are accounted for, so a third visit to the form
        // opens with nothing to send rather than with the first two again.
        #expect(CommunityPublisher.alreadySentPhotoIDs(of: hike).count == 3)
    }

    @Test("a contribution that never left stamps nothing")
    func afailedContributionStampsNothing() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()
        transport.submissionResult = .failure(CommunityFailure.unreachable)

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: CommunityPhotoTarget(listingID: "listing-1", title: "Almbachklamm"),
            authorName: "Ada",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .refused(.unreachable))
        // The contract the two publisher suites already pin, asked of the new
        // column: nothing is written down until CloudKit has accepted it, or
        // a hiker whose upload failed would be unable to send those pictures
        // ever again.
        #expect(CommunityPublisher.alreadySentPhotoIDs(of: hike).isEmpty)
    }

    @Test("a picture sent twice keeps the stamp it got the first time")
    func theFirstStampStands() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        let first = HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_060))
        hike.photos.append(contentsOf: [first, second])
        let sent = Date(timeIntervalSince1970: 1_700_001_000)
        let later = Date(timeIntervalSince1970: 1_700_009_000)

        CommunityPublisher.markSent([first.id], on: hike, at: sent)
        CommunityPublisher.markSent([first.id, second.id], on: hike, at: later)

        let stamps = Dictionary(
            uniqueKeysWithValues: hike.photos.map { ($0.id, $0.sentToCommunityAt) }
        )
        #expect(stamps[first.id] == sent)
        #expect(stamps[second.id] == later)
    }

    @Test("an id belonging to no row of this hike marks nothing")
    func aStrangerIDMarksNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Almbachklamm")
        hike.photos.append(HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        CommunityPublisher.markSent([UUID()], on: hike)

        #expect(CommunityPublisher.alreadySentPhotoIDs(of: hike).isEmpty)
    }

    // MARK: - What the strip says about them

    @Test("a tile that has already gone says so, whichever way it is pointing")
    func theStripNamesWhatHasAlreadyGone() {
        var photo = HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        photo.sentToCommunityAt = Date(timeIntervalSince1970: 1_700_001_000)

        let struckOff = CommunitySharePhotoStrip.label(for: photo, isExcluded: true, among: 3)
        let putBack = CommunitySharePhotoStrip.label(for: photo, isExcluded: false, among: 3)

        // The difference a tile cannot draw: struck off by the form because a
        // copy is already up there, as against struck off by the hiker.
        #expect(struckOff.contains("already sent"))
        #expect(putBack.contains("already sent"))
        let fresh = CommunitySharePhotoStrip.label(
            for: HikePhoto(capturedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            isExcluded: true,
            among: 3
        )
        #expect(!fresh.contains("already sent"))
    }
}
