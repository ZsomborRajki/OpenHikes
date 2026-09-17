//
//  CommunityImportContributionTests.swift
//  OpenHikesTests
//
//  What a saved hike holds when other hikers have added photographs to the
//  trail it was saved from.
//
//  ## The bug these were written against
//
//  A hiker saved a community trail, took a picture on it, contributed that
//  picture back, had it published, deleted their copy of the hike and saved
//  the trail again. The preview drew their photograph — the strip merges the
//  author's pictures and everybody's contributions, deliberately — and the
//  saved hike came back without it. ``CommunityImport`` copied only the
//  submission's own photographs and stepped over
//  ``CommunityHikeDetail/contributions`` entirely.
//
//  It was never only about the hiker's own picture. Contributing is how a
//  photograph reaches a trail somebody else published, so *every* photograph
//  added to a trail after it went live was dropped on the way into the
//  library, and a hiker saving a hike from a strip of eight got three with
//  nothing anywhere saying where the other five went.
//
//  ## What has to stay true while they come across
//
//  **They are still not the hiker's own.** A contributed copy is stamped with
//  the listing exactly as the author's copies are, so ``HikePhoto/isOwn`` is
//  false and ``CommunityPublisher/ownPhotos(of:)`` keeps it out of any
//  contribution aimed back at the same trail. That matters more for these than
//  for the author's: these are *already on the listing*, so re-sending one
//  would land a second copy of it in the gallery it was copied out of.
//
//  **They carry their own credit.** The hike's ``Hike/importedAuthorName``
//  names whoever published the walk, which is the wrong person for a picture
//  somebody else contributed — so the name travels per photograph, on
//  ``HikePhoto/importedAuthorName``.
//
//  **One bad set costs only itself.** Each contribution is a record with its
//  own pins and its own files, and the pairing is checked per set rather than
//  once for the lot.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community import contributions")
struct CommunityImportContributionTests {
    private static let listingID = "listing-1"
    private static let takenOn = Date(timeIntervalSince1970: 1_700_000_000)

    /// A directory of real JPEGs, removed when the test leaves.
    ///
    /// Real bytes rather than a placeholder because the import detects the
    /// format from the file itself — see ``ImageDataFormat/detect(in:)``,
    /// which refuses anything it cannot decode, so a stub would make every
    /// assertion below pass for the wrong reason.
    private final class Staging {
        let directory: URL

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CommunityImportContributionTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func files(_ names: [String]) -> [URL] {
            names.map { name in
                let url = directory.appendingPathComponent("\(name).jpeg", isDirectory: false)
                try? PhotoDiscoveryFixture.sampleImageData().write(to: url)
                return url
            }
        }
    }

    private static func pin(_ index: Int) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: takenOn.addingTimeInterval(Double(index) * 60),
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6 + Double(index) / 1000,
                longitude: 12.8
            )
        )
    }

    private static func contribution(
        id: String,
        author: String,
        files: [URL],
        pins: [CommunityPhotoPin] = []
    ) -> CommunityPhotoContribution {
        CommunityPhotoContribution(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: author,
            authorID: "\(id)-author",
            publishedAt: takenOn,
            photoPins: pins.isEmpty ? files.indices.map { pin($0) } : pins,
            photoFileURLs: files,
            photosOnRecord: files.count
        )
    }

    private static func detail(
        ownFiles: [URL] = [],
        ownPins: [CommunityPhotoPin] = [],
        contributions: [CommunityPhotoContribution] = []
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: .stub(),
            route: Fixture.ridgeRoute,
            trackDescription: "A ridge walk",
            photoPins: ownPins.isEmpty ? ownFiles.indices.map { pin($0) } : ownPins,
            photoFileURLs: ownFiles,
            photosOnRecord: ownFiles.count,
            contributions: contributions
        )
    }

    private func imported(
        _ detail: CommunityHikeDetail,
        in sandbox: PhotoStoreSandbox
    ) async throws -> Hike {
        let context = try Fixture.modelContext()
        let outcome = await CommunityImport.importHike(
            detail,
            into: context,
            store: sandbox.store,
            libraryWriter: StubPhotoLibraryWriter()
        )
        return try #require(outcome.hike)
    }

    /// The reported bug, in one assertion: what the preview drew is what the
    /// library gets.
    @Test("a saved hike holds the photographs contributed to the trail as well as its author's")
    func contributedPhotographsAreSaved() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                ownFiles: staging.files(["own-0"]),
                contributions: [
                    Self.contribution(
                        id: "c1",
                        author: "Bence",
                        files: staging.files(["c1-0", "c1-1"])
                    ),
                ]
            ),
            in: sandbox
        )

        #expect(
            hike.photos.count == 3,
            "the author's one and the two contributed to the trail"
        )
    }

    /// And each one says who took it, because the hike's own *Shared by*
    /// names the person who published the route rather than the person who
    /// took this picture.
    @Test("a contributed copy carries its contributor's credit, and the author's carries none")
    func contributedCopiesCarryTheirCredit() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                ownFiles: staging.files(["own-0"]),
                contributions: [
                    Self.contribution(id: "c1", author: "Bence", files: staging.files(["c1-0"])),
                    Self.contribution(id: "c2", author: "Cili", files: staging.files(["c2-0"])),
                ]
            ),
            in: sandbox
        )

        let credits = Set(hike.photos.compactMap(\.importedAuthorName))
        #expect(credits == ["Bence", "Cili"])
        #expect(
            hike.photos.filter { $0.importedAuthorName == nil }.count == 1,
            "the author's own photograph is credited by the hike, not by itself"
        )
    }

    /// A contributor who asked for no credit is an absence rather than a
    /// blank: there is nobody to name, and the photograph still arrives.
    @Test("a contribution published without a name still arrives, uncredited")
    func anUncreditedContributionStillArrives() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                contributions: [
                    Self.contribution(id: "c1", author: "", files: staging.files(["c1-0"])),
                ]
            ),
            in: sandbox
        )

        let photo = try #require(hike.photos.first)
        #expect(hike.photos.count == 1)
        #expect(photo.importedAuthorName == nil)
        #expect(!photo.isOwn, "no credit is not the same as the hiker's own")
    }

    /// The guard that matters most here. These pictures are already on the
    /// listing, so one offered back to it would be a second copy of itself in
    /// the gallery it came out of — under the importer's name.
    @Test("contributed copies are nobody's to publish, so nothing offers to send them back")
    func contributedCopiesAreNotTheHikersOwn() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                ownFiles: staging.files(["own-0"]),
                contributions: [
                    Self.contribution(
                        id: "c1",
                        author: "Bence",
                        files: staging.files(["c1-0", "c1-1"])
                    ),
                ]
            ),
            in: sandbox
        )

        #expect(hike.photos.allSatisfy { $0.importedFromListingID == Self.listingID })
        #expect(hike.photos.allSatisfy { !$0.isOwn })
        #expect(
            CommunityPublisher.ownPhotos(of: hike).isEmpty,
            "a saved hike has nothing of its own to contribute back"
        )
    }

    /// Per set, because each is a record of its own. A set whose pins and
    /// files disagree cannot say which photograph was taken where, so it
    /// brings none of its own — and takes nobody else's with it.
    @Test("a contribution whose pins do not describe its files costs only that set")
    func oneBadSetCostsOnlyItself() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                ownFiles: staging.files(["own-0"]),
                contributions: [
                    Self.contribution(
                        id: "bad",
                        author: "Bence",
                        files: staging.files(["bad-0", "bad-1"]),
                        pins: [Self.pin(0)]
                    ),
                    Self.contribution(id: "good", author: "Cili", files: staging.files(["good-0"])),
                ]
            ),
            in: sandbox
        )

        #expect(hike.photos.count == 2, "the author's one and the set that still describes itself")
        #expect(hike.photos.compactMap(\.importedAuthorName) == ["Cili"])
    }

    /// And the other way round. A submission whose own two arrays disagree is
    /// a fact about the submission; letting it cost the contributed sets would
    /// hide pictures that are perfectly well described because somebody
    /// else's are not.
    @Test("a submission whose pins do not describe its files still brings the contributions")
    func aMismatchedSubmissionStillBringsTheContributions() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let hike = try await imported(
            Self.detail(
                ownFiles: staging.files(["own-0", "own-1"]),
                ownPins: [Self.pin(0)],
                contributions: [
                    Self.contribution(id: "c1", author: "Bence", files: staging.files(["c1-0"])),
                ]
            ),
            in: sandbox
        )

        #expect(hike.photos.count == 1, "the author's pairing is unusable and the contribution is not")
        #expect(hike.photos.first?.importedAuthorName == "Bence")
        #expect(hike.route.count == Fixture.ridgeRoute.count, "and the walk is untouched either way")
    }

    /// Where each contributed photograph sits on the trail, which is the pin
    /// its own set carried rather than the one next door — see
    /// ``CommunityPhotoContribution/isConsistent`` for what backs that claim.
    @Test("a contributed photograph keeps the place it was taken")
    func contributedPhotographsKeepTheirPins() async throws {
        let staging = Staging()
        let sandbox = PhotoStoreSandbox()
        let pinned = CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.8605)
        let hike = try await imported(
            Self.detail(
                contributions: [
                    Self.contribution(
                        id: "c1",
                        author: "Bence",
                        files: staging.files(["c1-0"]),
                        pins: [CommunityPhotoPin(capturedAt: Self.takenOn, coordinate: pinned)]
                    ),
                ]
            ),
            in: sandbox
        )

        let photo = try #require(hike.photos.first)
        #expect(photo.coordinate?.latitude == pinned.latitude)
        #expect(photo.coordinate?.longitude == pinned.longitude)
        #expect(photo.capturedAt == Self.takenOn)
    }
}
