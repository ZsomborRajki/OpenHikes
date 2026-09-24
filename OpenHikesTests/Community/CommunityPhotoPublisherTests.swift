//
//  CommunityPhotoPublisherTests.swift
//  OpenHikesTests
//
//  What actually leaves the device when a hiker adds their photographs to
//  somebody else's trail, and what is written down afterwards.
//
//  ``CommunityPublisherTests`` next door asks the same questions of a hike
//  share, and the two suites are deliberately shaped alike: the contract being
//  pinned is the same one — **nothing is recorded until CloudKit has accepted
//  it** — and the failure it exists to prevent is the same one, which is a
//  hiker being told their pictures are waiting for review when nothing left.
//
//  Two things are only true here, and they are what the suite is really for.
//
//  **The target is the whole of the aim.** A contribution names a listing by
//  ``CommunityIdentity``, so the one thing no downstream check could ever
//  catch is the photographs being published onto the wrong trail. Every test
//  that sends anything asserts the id that went with it.
//
//  **An empty contribution is refused rather than sent.** A hike share refuses
//  a hike with no route; this refuses a set with no photographs, and the empty
//  case is *ordinary* here — a trail somebody saved and has not yet walked
//  with a camera reaches the same button. It is refused twice over: once
//  against the rows, and once against the files, which is the only place the
//  device-local-pixels rule shows up.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community photo publisher")
struct CommunityPhotoPublisherTests {
    private static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Almbachklamm",
        authorName: "Anna"
    )

    /// Attaches `count` photo rows whose pixels are on this device.
    ///
    /// The same helper ``CommunitySharePhotoCountTests`` uses, and for the same
    /// reason it is a helper: a row with no file behind it and a row with one
    /// are the two cases this whole feature has to tell apart.
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

    @Test("the photographs and the target go up, and nothing else does")
    func draftCarriesThePhotographs() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "My walk up the gorge")
        await addStoredPhotos(3, to: hike, in: sandbox)
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
        #expect(draft.target.listingID == "listing-1")
        #expect(draft.authorName == "Bern")
        #expect(draft.photoFileURLs.count == 3)
        // A pin per photograph, which is the invariant the two record fields
        // describe each other by.
        #expect(draft.photoPins.count == draft.photoFileURLs.count)
        // And the hike's own walk is not in it: no route, no title, no notes,
        // because the trail already has all three from whoever published it.
        // A draft field carrying one would be a promise
        // ``CommunityPhotoDisclosure`` does not make.
        #expect(draft.takenOn == hike.date)
        // No hike share happened alongside it.
        #expect(transport.recording.submissions.isEmpty)
    }

    /// Where the reviewer's map stands, which is the whole of what a
    /// contribution can be judged against — see ``CommunityPhotoReviewView``.
    @Test("the contribution is located at the first photograph that knows where it was")
    func draftStartsAtTheFirstAnchoredPhoto() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "",
            transport: transport,
            store: sandbox.store
        )

        let draft = try #require(transport.recording.photoDrafts.first)
        let start = try #require(draft.startCoordinate)
        #expect(start.latitude == draft.photoPins.first?.latitude)
    }

    /// The ordinary empty case, and it must never reach the network: a
    /// submission with no assets is a record in a public database, a row in a
    /// reviewer's queue, and a hiker told their pictures are waiting.
    @Test("a hike with no photographs sends nothing")
    func nothingToSend() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport
        )

        #expect(outcome == .refused(.noPhotosToShare))
        #expect(transport.recording.photoDrafts.isEmpty)
        #expect(hike.communityPhotoSubmissionID == nil)
    }

    /// The case only this app has: rows that mirrored between a hiker's
    /// devices and files that never do. A full strip on the iPad and nothing
    /// behind any of it is refused at the *files* rather than at the rows,
    /// which is the only place that distinction can be made.
    @Test("a strip whose pixels are on another device sends nothing")
    func photosOnAnotherDeviceSendNothing() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        for _ in 0..<4 {
            hike.photos.append(HikePhoto())
        }
        let transport = StubCommunityTransport()

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .refused(.noPhotosToShare))
        #expect(transport.recording.photoDrafts.isEmpty)
    }

    /// The contract this file's header calls the point: a contribution that
    /// failed must not leave the device believing the pictures were sent,
    /// because nothing can ever correct that belief — a photo submission has
    /// no listing that could lead back to it.
    @Test("a refused upload writes nothing down")
    func failedContributionRecordsNothing() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()
        transport.submissionResult = .failure(.unreachable)

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .refused(.unreachable))
        #expect(hike.communityPhotoSubmissionID == nil)
        #expect(hike.communityPhotoContributionID == nil)
    }

    @Test("an accepted upload is remembered on the hike")
    func acceptedContributionIsRecorded() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()
        transport.submissionResult = .success("photo-submission-42")

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(hike.communityPhotoSubmissionID == "photo-submission-42")
        // The hike's own publication columns are untouched: contributing
        // photographs to somebody else's trail says nothing about whether this
        // walk was ever shared.
        #expect(hike.communitySubmissionID == nil)
        #expect(hike.communityListingID == nil)
    }

    /// The two columns are one answer about one upload. A second send that
    /// left the first one's *published* answer standing would report a
    /// contribution nobody has reviewed as live — and, worse, silently: the
    /// check skips a hike that already has one.
    @Test("a second send clears the answer about the first")
    func secondSendClearsTheStaleAnswer() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        hike.communityPhotoSubmissionID = "photo-submission-1"
        hike.communityPhotoContributionID = "contribution-1"
        let transport = StubCommunityTransport()
        transport.submissionResult = .success("photo-submission-2")

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(hike.communityPhotoSubmissionID == "photo-submission-2")
        #expect(hike.communityPhotoContributionID == nil)
    }

    /// The exclusion the form's strip produces, applied before the cap the way
    /// a hike share applies it — the rule
    /// ``CommunitySharePhotoChoiceTests`` pins for the other publisher, asked
    /// here because the two share ``CommunityPublisher/selectedPhotos(of:excluding:)``
    /// and a contribution that filtered afterwards would be a second answer to
    /// one question.
    @Test("a struck-off photograph does not go")
    func exclusionIsHonoured() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(3, to: hike, in: sandbox)
        let excluded = try #require(hike.orderedPhotos.first)
        let transport = StubCommunityTransport()

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            excludingPhotos: [excluded.id],
            store: sandbox.store
        )

        let draft = try #require(transport.recording.photoDrafts.first)
        #expect(draft.photoFileURLs.count == 2)
        #expect(draft.photoPins.count == 2)
        #expect(!draft.photoPins.contains { $0.capturedAt == excluded.capturedAt })
    }

    /// Staged where the sweep can reach it, and under a name that says which
    /// kind of upload left it behind — the rule ``CommunityStaging`` states,
    /// asked of the contribution path because a kill mid-upload is how a long
    /// send in the background usually ends.
    @Test("everything staged lands inside the directory the sweep owns")
    func stagingStaysInsideTheSweptDirectory() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "",
            transport: transport,
            store: sandbox.store
        )

        let draft = try #require(transport.recording.photoDrafts.first)
        let parent = CommunityStaging.directory.standardizedFileURL.path
        #expect(draft.stagingDirectory.standardizedFileURL.path.hasPrefix(parent))
        #expect(draft.stagingDirectory.lastPathComponent.hasPrefix("CommunityPhotos-"))
        for url in draft.photoFileURLs {
            #expect(url.standardizedFileURL.path.hasPrefix(parent))
        }
    }
}
