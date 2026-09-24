//
//  CommunityImportedPhotoGuardTests.swift
//  OpenHikesTests
//
//  The one photograph a hiker must never be able to publish: somebody else's,
//  sitting in their own library because they saved the hike it came with.
//
//  ## Why the two halves of this feature meet here
//
//  ``CommunityImport`` copies a listing's photographs into the saved hike, so
//  a trail somebody saved is useful offline and looks like a hike rather than
//  a line on a map. ``CommunityPublishingEligibility`` then refuses to publish
//  that hike *and offers to send its photographs instead*, aimed at the very
//  listing they were copied out of.
//
//  Those two are individually right and, without provenance, together wrong:
//  the *Add Photos* form opened pre-selected with the original author's
//  pictures, one tap from re-publishing them onto their own trail under the
//  importer's credit — with no credit anywhere, since the copies carry none.
//  ``HikePhoto/importedFromListingID`` is what tells them apart, and these are
//  what hold it to that job.
//
//  ## Why the gate is asserted on the publisher and not on the form
//
//  Because the form is one of two callers. ``CommunityPublisher/ownPhotos(of:)``
//  is the single gate both the strip and the upload go through, so a test that
//  drove the screen would pin the screen rather than the rule. What goes on
//  the wire is the claim worth making, and it is made against a real draft.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community imported photo guard")
struct CommunityImportedPhotoGuardTests {
    private static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Almbachklamm",
        authorName: "Anna"
    )

    /// Attaches `count` photo rows whose pixels are really on this device,
    /// stamped with `listingID` when they are meant to be somebody else's.
    @discardableResult private func addStoredPhotos(
        _ count: Int,
        to hike: Hike,
        in sandbox: PhotoStoreSandbox,
        importedFrom listingID: String? = nil,
        firstCaptureOffset: Double = 0
    ) async -> [HikePhoto] {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        var added: [HikePhoto] = []
        for index in 0..<count {
            let captured = Date(
                timeIntervalSince1970: 1_700_000_000 + firstCaptureOffset + Double(index) * 60
            )
            let origin = HikePhoto.Origin(importedFromListingID: listingID)
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(
                    data,
                    capturedAt: captured,
                    coordinate: CLLocationCoordinate2D(
                        latitude: 47.6 + Double(index) / 10_000,
                        longitude: 12.8
                    ),
                    origin: origin
                )
            }).value else { continue }
            hike.photos.append(photo)
            added.append(photo)
        }
        return added
    }

    /// The case the whole file is about: a hike saved from the community,
    /// never walked with a camera, offering its author's own pictures back to
    /// them.
    @Test("a saved hike with only the author's photographs has nothing to contribute")
    func importedPhotographsAreNotAContribution() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(3, to: hike, in: sandbox, importedFrom: "listing-1")
        let transport = StubCommunityTransport()

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        // Refused as an empty set, which is the honest answer: this device has
        // nothing of its own to send.
        #expect(outcome == .refused(.noPhotosToShare))
        #expect(transport.recording.photoDrafts.isEmpty)
        #expect(hike.communityPhotoSubmissionID == nil)
    }

    /// The ordinary case once the hiker has walked it themselves: their own
    /// pictures go and the imported ones stay, rather than the whole hike
    /// being refused.
    @Test("a saved hike the hiker photographed sends only their own pictures")
    func ownPhotographsGoAndImportedOnesDoNot() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox, importedFrom: "listing-1")
        let mine = await addStoredPhotos(
            3,
            to: hike,
            in: sandbox,
            firstCaptureOffset: 10_000
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
        #expect(draft.photoFileURLs.count == 3)
        // Identified by the minute they were taken, which is what survives the
        // trip: the upload carries pins rather than rows.
        #expect(draft.photoPins.map(\.capturedAt).sorted() == mine.map(\.capturedAt).sorted())
    }

    /// The same rule read off the gate itself, because both the strip the
    /// hiker chooses from and the upload go through it — a form drawing a
    /// picture the publisher would drop is an offer the app cannot keep.
    @Test("the form and the upload are offered the same photographs")
    func theStripAndTheUploadAgree() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox, importedFrom: "listing-1")
        await addStoredPhotos(1, to: hike, in: sandbox, firstCaptureOffset: 10_000)

        #expect(hike.photos.count == 3)
        #expect(CommunityPublisher.ownPhotos(of: hike).count == 1)
        #expect(CommunityPublisher.shareablePhotos(of: hike).count == 1)
        #expect(CommunityPublisher.selectedPhotos(of: hike).count == 1)
        #expect(CommunityPublisher.shareablePhotos(of: hike).first?.isOwn == true)
    }

    /// The second thing the gate refuses, and it refuses it for a different
    /// reason: a place-only row is the hiker's own — nobody else's work is at
    /// stake — but there is no picture behind it to upload. Offering it would
    /// put a tile in the form that can only ever send nothing.
    @Test("a row read out of a GPX waypoint is not offered for publishing")
    func aPlaceOnlyRowIsNotOffered() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(1, to: hike, in: sandbox)
        hike.photos.append(HikePhoto(isPlaceOnly: true))

        #expect(hike.photos.count == 2)
        // Its own, and still not publishable — which is the distinction that
        // would be lost if the gate only asked `isOwn`.
        let everyRowIsTheHikersOwn = hike.photos.allSatisfy(\.isOwn)
        #expect(everyRowIsTheHikersOwn)
        #expect(CommunityPublisher.ownPhotos(of: hike).count == 1)
        #expect(CommunityPublisher.shareablePhotos(of: hike).count == 1)
        #expect(CommunityPublisher.shareablePhotos(of: hike).first?.recordsPlaceOnly == false)
    }

    /// A photograph written before this field existed decodes without one, and
    /// the absence has to read as *the hiker's own* — anything else would hide
    /// every picture anybody already had.
    @Test("a photograph with no provenance is the hiker's own")
    func absentProvenanceMeansOwn() {
        let photo = HikePhoto(capturedAt: .now)

        #expect(photo.importedFromListingID == nil)
        #expect(photo.isOwn)
    }
}
