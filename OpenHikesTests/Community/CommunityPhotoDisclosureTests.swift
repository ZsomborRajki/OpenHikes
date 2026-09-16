//
//  CommunityPhotoDisclosureTests.swift
//  OpenHikesTests
//
//  The sentence under *What gets added*, held against what a contribution
//  actually carries.
//
//  ``CommunityShareDisclosureTests`` next door does this for a hike share, and
//  the reason both exist is the failure that suite was written for: the promise
//  and the payload live in different files, and the first version of the share
//  screen said "nothing else from this hike" while the upload carried the
//  description, the date and a timestamp on every point of the route.
//
//  Here the promise is the *smaller* one and that is what makes it worth
//  pinning. A contribution says the route, the notes and the walk's name stay
//  on the device — so the test that matters is the one that would fail if
//  ``CommunityPhotoDraft`` ever grew a field carrying one of them.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community photo disclosure")
struct CommunityPhotoDisclosureTests {
    private static let trail = "Almbachklamm"

    /// The fields a contribution is allowed to have.
    ///
    /// Spelled out as a list rather than checked one by one, so a field added
    /// to ``CommunityPhotoDraft`` fails here rather than shipping undisclosed
    /// — the rule that makes this suite worth having. Each is either disclosed
    /// by the sentence or is machinery the sentence does not have to mention,
    /// and which is which is stated beside it.
    private static let disclosedFields = Set([
        // Disclosed: "photos go on <trail>".
        "photoFileURLs",
        // Disclosed: "with the spot on the trail and the time it was taken at".
        "photoPins",
        // Disclosed: the sentence names the trail these are joining.
        "target",
        // Disclosed by the form's own *Shared as* row rather than by this
        // sentence, which is where a hiker types it.
        "authorName",
        // Not sent as a fact about the walk: it is the reviewer's row date and
        // is the same day every pin already carries.
        "takenOn",
        // Machinery. The hike id names the staging directory and never leaves
        // the device; the directory is deleted on every exit.
        "hikeID",
        "stagingDirectory",
    ])

    /// Attaches `count` photo rows whose pixels are on this device.
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
                    coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
                )
            }).value else { continue }
            hike.photos.append(photo)
        }
    }

    /// Against a real draft, which is the only version of this question worth
    /// asking: a mirror asserted against a mirror agrees with itself.
    @Test("every field a contribution carries is one the sentence accounts for")
    func nothingUndisclosed() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "My walk")
        hike.trackDescription = "Wet rock after rain."
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: CommunityPhotoTarget(
                listingID: "listing-1",
                title: Self.trail,
                authorName: "Anna"
            ),
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        let draft = try #require(transport.recording.photoDrafts.first)
        let carried = Set(Mirror(reflecting: draft).children.compactMap(\.label))
        #expect(
            carried.subtracting(Self.disclosedFields).isEmpty,
            """
            CommunityPhotoDraft carries \(carried.subtracting(Self.disclosedFields)), \
            which the disclosure does not account for
            """
        )
        // And the other direction: a field listed here that the draft no
        // longer has is a list that has rotted into an exemption for nothing.
        #expect(Self.disclosedFields.subtracting(carried).isEmpty)
    }

    /// The three things the hike share sends and this one deliberately does
    /// not. The sentence says so out loud, because that asymmetry *is* the
    /// feature — a hiker who has read the share form is entitled to assume
    /// this one behaves the same way unless it says otherwise.
    @Test("the route, the notes and the name are promised to stay")
    func theWalkStaysBehind() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context, title: "My walk")
        hike.trackDescription = "Wet rock after rain."
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = StubCommunityTransport()

        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: CommunityPhotoTarget(listingID: "listing-1", title: Self.trail, authorName: nil),
            authorName: "",
            transport: transport,
            store: sandbox.store
        )

        let draft = try #require(transport.recording.photoDrafts.first)
        let text = CommunityPhotoDisclosure.text(photoCount: 2, trailTitle: Self.trail)
        #expect(text.contains("stay on your device"))
        // Asserted against the draft rather than against the sentence's own
        // wording, which is the point of the suite: the promise holds because
        // there is no field for a route to travel in.
        let carried = Set(Mirror(reflecting: draft).children.compactMap(\.label))
        #expect(!carried.contains("route"))
        #expect(!carried.contains("trackDescription"))
        #expect(!carried.contains("title"))
    }

    /// One photograph reads as written English rather than as a template with
    /// a 1 in it — the rule every other counted sentence in this feature
    /// follows.
    @Test("one photograph is not \"1 photos\"")
    func oneReadsAsEnglish() {
        let one = CommunityPhotoDisclosure.text(photoCount: 1, trailTitle: Self.trail)
        #expect(one.contains("One photo"))
        #expect(!one.contains("1 photo"))

        let several = CommunityPhotoDisclosure.text(photoCount: 4, trailTitle: Self.trail)
        #expect(several.contains("4 photos"))
    }

    /// The trail is named in every version of the sentence, including the
    /// empty one, because the whole risk this screen carries is a hiker
    /// sending pictures to a trail they did not mean.
    @Test("the trail is named whether or not anything is going")
    func theTrailIsAlwaysNamed() {
        #expect(CommunityPhotoDisclosure.text(photoCount: 0, trailTitle: Self.trail)
            .contains(Self.trail))
        #expect(CommunityPhotoDisclosure.text(photoCount: 3, trailTitle: Self.trail)
            .contains(Self.trail))
    }

    /// A hike with nothing to send says so rather than promising photographs.
    /// The ordinary state of a trail somebody saved and has not walked yet.
    @Test("no photographs promises none")
    func nonePromisesNothing() {
        let text = CommunityPhotoDisclosure.text(photoCount: 0, trailTitle: Self.trail)
        #expect(text.contains("Nothing yet"))
        #expect(!text.contains("goes on"))
    }
}
