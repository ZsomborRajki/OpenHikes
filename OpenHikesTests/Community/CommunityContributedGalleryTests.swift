//
//  CommunityContributedGalleryTests.swift
//  OpenHikesTests
//
//  Where each photograph sits once a hike's own pictures and everybody else's
//  are drawn as one strip.
//
//  ## Why the arithmetic is worth a suite
//
//  Because the index is not decoration. ``CommunityGalleryPhoto/index`` and
//  ``CommunityPreviewPhoto/index`` are the same number about the same picture,
//  and three separate things read it: the gallery pages by position in the
//  array, the map's callout opens the page its pin names, and the strip's
//  accessibility identifier is built from it. Number a contributed set from
//  zero instead of from where it sits and every one of those three lands on
//  the wrong photograph — silently, and with a screen full of pictures that
//  all look plausible.
//
//  ## Why the submission's own four fields must stay separate
//
//  ``CommunityHikeDetail/photoFileURLs`` and its three companions describe the
//  **submission**: they are what ``CommunityHikeDetail/hasEveryPhoto`` is
//  asked about and what ``CommunityHikeDetail/keptPhotos(at:)`` rewrites onto
//  the record. A reviewer striking a photograph off a hike must never be able
//  to reach a picture somebody else owns, so a merge that folded the
//  contributions into those arrays would hand a reviewer a delete of another
//  person's photograph with nothing anywhere saying so. These pin that the
//  merge happens on the way *out*, in the two computed galleries, and nowhere
//  else.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Community contributed gallery")
struct CommunityContributedGalleryTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func pin(_ index: Int, anchored: Bool = true) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: hikeDate.addingTimeInterval(Double(index) * 60),
            coordinate: anchored
                ? CLLocationCoordinate2D(latitude: 47.6 + Double(index) / 1000, longitude: 12.8)
                : nil
        )
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).jpeg")
    }

    /// A hike with `own` photographs of its author's.
    private static func detail(
        own: Int,
        contributions: [CommunityPhotoContribution] = []
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: .stub(),
            route: [],
            trackDescription: nil,
            photoPins: (0..<own).map { pin($0) },
            photoFileURLs: (0..<own).map { url("own-\($0)") },
            photosOnRecord: own,
            contributions: contributions
        )
    }

    private static func contribution(
        id: String,
        author: String,
        count: Int,
        authorID: String = "author-1",
        anchored: Bool = true
    ) -> CommunityPhotoContribution {
        CommunityPhotoContribution(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: author,
            authorID: authorID,
            publishedAt: hikeDate,
            photoPins: (0..<count).map { pin($0, anchored: anchored) },
            photoFileURLs: (0..<count).map { url("\(id)-\($0)") },
            photosOnRecord: count
        )
    }

    /// The ordinary case, and the one every hike was in before this existed:
    /// nothing contributed, and a gallery that must read exactly as it did.
    @Test("a hike with no contributions draws exactly its own photographs")
    func noContributionsChangesNothing() {
        let detail = Self.detail(own: 3)

        #expect(detail.galleryPhotos.count == 3)
        #expect(detail.galleryPhotos.map(\.index) == [0, 1, 2])
        #expect(detail.galleryPhotos.allSatisfy { $0.contribution == nil })
        #expect(detail.galleryPhotos.allSatisfy { $0.credit == nil })
        #expect(detail.galleryPhotos == detail.ownGalleryPhotos)
    }

    /// The numbering, which is the whole of this file. The author's come
    /// first, then each set in publication order, and the positions run
    /// unbroken across all of them.
    @Test("contributed photographs are numbered on from the author's")
    func indexesRunOnAcrossSets() {
        let detail = Self.detail(
            own: 2,
            contributions: [
                Self.contribution(id: "c1", author: "Anna", count: 3),
                Self.contribution(id: "c2", author: "Bern", count: 1, authorID: "author-2"),
            ]
        )

        let gallery = detail.galleryPhotos
        #expect(gallery.map(\.index) == [0, 1, 2, 3, 4, 5])
        // Whose is whose, which is the half an off-by-one would still get
        // right if it only checked the count.
        #expect(gallery.map(\.credit) == [nil, nil, "Anna", "Anna", "Anna", "Bern"])
        #expect(gallery[2].fileURL == Self.url("c1-0"))
        #expect(gallery[5].fileURL == Self.url("c2-0"))
    }

    /// A hike whose author published nothing is the case this feature exists
    /// for — a curated OpenStreetMap trail is always in it — so the first
    /// contributed photograph has to be photograph zero.
    @Test("a hike with no photographs of its own starts at the contributions")
    func aTrailWithNoPicturesOfItsOwn() {
        let detail = Self.detail(
            own: 0,
            contributions: [Self.contribution(id: "c1", author: "Anna", count: 2)]
        )

        #expect(detail.galleryPhotos.map(\.index) == [0, 1])
        #expect(detail.galleryPhotos.map(\.credit) == ["Anna", "Anna"])
    }

    /// The map's pins and the gallery's pages identify one picture by one
    /// number. A pin tapped on the map opens the page the strip would, so the
    /// two lists have to agree about every index they share.
    @Test("a contributed pin names the page the strip would open")
    func pinsAndPagesAgree() {
        let detail = Self.detail(
            own: 1,
            contributions: [Self.contribution(id: "c1", author: "Anna", count: 2)]
        )

        let gallery = detail.galleryPhotos
        for preview in detail.previewPhotos {
            let page = gallery.first { $0.index == preview.index }
            #expect(page?.fileURL == preview.fileURL, "pin \(preview.index) names another picture")
        }
        #expect(detail.previewPhotos.map(\.index) == [0, 1, 2])
    }

    /// A photograph with nowhere to stand is left out of the *pins* and stays
    /// in the *gallery* — the rule a hike's own pictures already follow, and
    /// it has to hold set by set: an unanchored contributed picture must not
    /// renumber the anchored ones after it.
    @Test("an unanchored contributed photograph keeps its page and loses its pin")
    func unanchoredContributionsKeepTheirPage() {
        let detail = Self.detail(
            own: 1,
            contributions: [
                Self.contribution(id: "c1", author: "Anna", count: 2, anchored: false),
                Self.contribution(id: "c2", author: "Bern", count: 1, authorID: "author-2"),
            ]
        )

        #expect(detail.galleryPhotos.map(\.index) == [0, 1, 2, 3])
        // The two unanchored ones are absent from the pins and the last one
        // still stands at 3 rather than at 1.
        #expect(detail.previewPhotos.map(\.index) == [0, 3])
    }

    /// The invariant a set is judged on separately, because each is a record
    /// of its own: one contribution whose pins are wrong must not cost the
    /// others their places.
    @Test("an inconsistent set loses its pins and nobody else's")
    func oneBadSetCostsOnlyItsOwnPins() {
        var broken = Self.contribution(id: "c1", author: "Anna", count: 2)
        broken.photoPins = [Self.pin(0)]
        let detail = Self.detail(
            own: 1,
            contributions: [
                broken,
                Self.contribution(id: "c2", author: "Bern", count: 1, authorID: "author-2"),
            ]
        )

        #expect(!broken.isConsistent)
        // Still four pages: the gallery drops nothing, because a missing page
        // would make the fourth tile open the fifth photograph.
        #expect(detail.galleryPhotos.map(\.index) == [0, 1, 2, 3])
        // The broken set makes no claim about where its pictures were taken;
        // the author's and the other set's still do.
        #expect(detail.previewPhotos.map(\.index) == [0, 3])
    }

    /// The separation this file's header is about: the reviewer's four fields
    /// go on describing the submission alone, whatever is hanging off the
    /// detail beside them.
    @Test("contributions never reach what a reviewer would rewrite")
    func contributionsAreOutOfAReviewersReach() {
        let detail = Self.detail(
            own: 2,
            contributions: [Self.contribution(id: "c1", author: "Anna", count: 3)]
        )

        #expect(detail.photoFileURLs.count == 2)
        #expect(detail.photosOnRecord == 2)
        #expect(detail.hasEveryPhoto)
        // The rewrite is built from indexes into the submission's own files,
        // and asking for every index the *merged* gallery offers must not
        // reach a contributed picture.
        let kept = detail.keptPhotos(at: Set(0..<detail.galleryPhotos.count))
        #expect(kept.count == 2)
        #expect(kept.map(\.fileURL) == [Self.url("own-0"), Self.url("own-1")])
        // And the reviewer's own strip is the author's pictures alone.
        #expect(detail.ownGalleryPhotos.count == 2)
        #expect(detail.ownPreviewPhotos.count == 2)
    }

    /// Every fact a report, a block or a takedown needs, carried per
    /// photograph. A credit alone would name somebody a hiker could not block,
    /// which is the state ``CommunityPhotoAttribution`` exists to make
    /// unrepresentable.
    @Test("a contributed photograph carries both record names and its author")
    func attributionCarriesWhatTheMenuNeeds() throws {
        let detail = Self.detail(
            own: 0,
            contributions: [
                Self.contribution(id: "c1", author: "Anna", count: 1, authorID: "author-7"),
            ]
        )

        let attribution = try #require(detail.galleryPhotos.first?.contribution)
        #expect(attribution.contributionID == "c1")
        #expect(attribution.photoSubmissionID == "c1-submission")
        #expect(attribution.authorID == "author-7")
        #expect(attribution.credit == "Anna")
    }

    /// A contributor who asked for no credit is ordinary — the field is
    /// optional everywhere it is typed — and the menu still has to be able to
    /// block them, which is why the credit and the identity are different
    /// things.
    @Test("a contribution with no credit is still blockable")
    func anUncreditedContributionIsStillBlockable() throws {
        let detail = Self.detail(
            own: 0,
            contributions: [Self.contribution(id: "c1", author: "", count: 1, authorID: "author-7")]
        )

        let attribution = try #require(detail.galleryPhotos.first?.contribution)
        #expect(attribution.credit == nil)
        #expect(attribution.authorID == "author-7")
    }
}
