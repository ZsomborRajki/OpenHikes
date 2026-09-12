//
//  CommunitySharePhotoCountTests.swift
//  OpenHikesTests
//
//  The number on the share form, held against the number of files the upload
//  actually carries.
//
//  `CommunityShareDisclosureTests` asks the wording about a draft, which is
//  the right question for everything the sentence promises except this one:
//  the screen counted photo *rows* and the upload carries photo *files*, and
//  the two differ permanently on any device the pictures were not imported on
//  — a walk recorded on the phone has its whole strip on the iPad with nothing
//  behind any of it. A hiker was told eight photographs went with the hike and
//  sent a submission with no assets at all.
//
//  So each of these computes the form's number the way the form does — through
//  `CommunityPublisher.sendablePhotoCount` — and asserts it against
//  `draft.photoFileURLs.count` from a real share, never against a count the
//  test worked out for itself.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community share photo count")
struct CommunitySharePhotoCountTests {
    /// A share run to completion, with what the form would have said and what
    /// the upload actually took.
    private struct Shared {
        var formCount: Int
        var draft: CommunitySubmissionDraft
    }

    /// Attaches `count` photo rows whose pixels are on this device.
    private func addStoredPhotos(_ count: Int, to hike: Hike, in sandbox: PhotoStoreSandbox) async {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        for index in 0..<count {
            let captured = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            guard let photo = await Task.detached(priority: .userInitiated, operation: {
                store.store(
                    data,
                    capturedAt: captured,
                    coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
                )
            }).value else { continue }
            hike.photos.append(photo)
        }
    }

    /// Shares `hike` and reports the form's number beside the upload's.
    ///
    /// The form's number is read *before* the share, which is when the screen
    /// reads it: the footer a hiker sees is written while they are deciding,
    /// not afterwards.
    private func share(
        _ hike: Hike,
        in sandbox: PhotoStoreSandbox
    ) async throws -> Shared {
        let formCount = await CommunityPublisher.sendablePhotoCount(
            of: hike,
            store: sandbox.store
        )
        let transport = StubCommunityTransport()
        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            entitlement: .entitled,
            transport: transport,
            store: sandbox.store
        )
        #expect(outcome == .submitted)
        return Shared(
            formCount: formCount,
            draft: try #require(transport.recording.submissions.first)
        )
    }

    /// The failure this suite exists for: rows with no files behind them are
    /// a full strip on screen and an empty submission on the wire.
    @Test("a hike whose photos are on another device promises none")
    func photosOnAnotherDeviceArePromisedToNobody() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        // Rows the store has no file for, which is exactly what a hike
        // recorded on another device looks like here.
        for _ in 0..<8 {
            hike.photos.append(HikePhoto())
        }

        let shared = try await share(hike, in: sandbox)

        #expect(shared.draft.photoFileURLs.isEmpty)
        #expect(shared.formCount == shared.draft.photoFileURLs.count)
        #expect(
            min(hike.photos.count, CommunityPublisher.maximumPhotos) == 8,
            "the number the form used to quote, and the size of the lie"
        )
        let footer = CommunityShareDisclosure.text(hasNotes: false, photoCount: shared.formCount)
        #expect(
            !footer.contains("photo"),
            "a footer promising photographs beside an upload carrying none"
        )
    }

    /// The ordinary case still has to come out right, or the fix would be a
    /// screen that never mentions photographs.
    @Test("a hike whose photos are here promises all of them")
    func photosOnThisDeviceArePromised() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(3, to: hike, in: sandbox)

        let shared = try await share(hike, in: sandbox)

        #expect(shared.draft.photoFileURLs.count == 3)
        #expect(shared.formCount == shared.draft.photoFileURLs.count)
    }

    /// Mixed is the case a hiker actually meets: some pictures taken on this
    /// phone, some added on the other one.
    @Test("a hike with some photos elsewhere promises only the ones here")
    func mixedPhotosPromiseOnlyTheReachableOnes() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        for _ in 0..<4 {
            hike.photos.append(HikePhoto())
        }

        let shared = try await share(hike, in: sandbox)

        #expect(shared.draft.photoFileURLs.count == 2)
        #expect(shared.formCount == shared.draft.photoFileURLs.count)
        #expect(shared.formCount < hike.photos.count, "the rows are not the files")
    }

    /// The cap sits on top of the same answer, and a hike over it with some
    /// pictures missing must not quote the cap.
    @Test("the cap and the missing files are applied to the same number")
    func theCapAndTheMissingFilesAgree() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(CommunityPublisher.maximumPhotos + 3, to: hike, in: sandbox)
        for _ in 0..<5 {
            hike.photos.append(HikePhoto())
        }

        let shared = try await share(hike, in: sandbox)

        #expect(shared.draft.photoFileURLs.count == CommunityPublisher.maximumPhotos)
        #expect(shared.formCount == shared.draft.photoFileURLs.count)
    }
}
