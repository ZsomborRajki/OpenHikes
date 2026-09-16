//
//  CommunityContributionVisibilityTests.swift
//  OpenHikesTests
//
//  What a trail's screen may still draw after the hiker has hidden something
//  from the gallery pushed over it.
//
//  ## Why this cannot be left to the request
//
//  ``CommunityTransporting/contributedPhotos(for:excluding:downloadingInto:)``
//  takes the blocked set and applies it before the download, which is where it
//  has to go: downloading a stranger's photographs *is* the cost. What that
//  cannot cover is a decision made after the request finished — and both
//  decisions this feature offers are made exactly there, in
//  ``CommunityPhotoActions``, one screen further in.
//
//  Backing out of that gallery is a pop and not a fetch.
//  ``CommunityHikeView/load()`` returns at once for a loaded phase,
//  deliberately, so re-entering the trail redraws the answer from before the
//  block. Without a filter on the draw, blocking a contributor popped the
//  gallery and left their pictures in the strip behind it, one tap from
//  reopening on them — which is the half of Guideline 1.2 that has to work
//  rather than merely be offered.
//
//  ## Why it is the whole detail and not the strip
//
//  Because the indexes are shared. ``CommunityHikeDetail/galleryPhotos`` and
//  ``CommunityHikeDetail/previewPhotos`` number the same pictures the same
//  way — see `CommunityContributedGalleryTests` — so a filter applied to one
//  and not the other would leave a map pin opening the page next to the one it
//  is about. These assert the numbers close up behind a removed set rather
//  than leaving a hole where it was.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community contribution visibility")
struct CommunityContributionVisibilityTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func pin(_ index: Int) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: hikeDate.addingTimeInterval(Double(index) * 60),
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6 + Double(index) / 1000,
                longitude: 12.8
            )
        )
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).jpeg")
    }

    private static func contribution(
        id: String,
        authorID: String,
        count: Int = 2
    ) -> CommunityPhotoContribution {
        CommunityPhotoContribution(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: "Author \(authorID)",
            authorID: authorID,
            publishedAt: hikeDate,
            photoPins: (0..<count).map { pin($0) },
            photoFileURLs: (0..<count).map { url("\(id)-\($0)") },
            photosOnRecord: count
        )
    }

    private static func detail(own: Int, _ sets: [CommunityPhotoContribution]) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: .stub(),
            route: [],
            trackDescription: nil,
            photoPins: (0..<own).map { pin($0) },
            photoFileURLs: (0..<own).map { url("own-\($0)") },
            photosOnRecord: own,
            contributions: sets
        )
    }

    /// The ordinary case, and the one almost every hiker is in: nothing
    /// blocked, nobody a reviewer, and a detail that must come back untouched
    /// rather than rebuilt.
    @Test("a hiker who has hidden nothing sees every set")
    func nothingHiddenChangesNothing() {
        let detail = Self.detail(own: 1, [
            Self.contribution(id: "c1", authorID: "author-1"),
            Self.contribution(id: "c2", authorID: "author-2"),
        ])

        let visible = detail.excluding(authors: [], contributions: [])

        #expect(visible.contributions.map(\.id) == ["c1", "c2"])
        #expect(visible.galleryPhotos == detail.galleryPhotos)
    }

    /// Blocking is keyed on the contributor, so it takes every set that person
    /// put on this trail rather than the one that was on screen.
    @Test("blocking a contributor takes all of their sets off the trail")
    func blockingTakesEverySetFromThatContributor() {
        let detail = Self.detail(own: 0, [
            Self.contribution(id: "c1", authorID: "author-1"),
            Self.contribution(id: "c2", authorID: "author-2"),
            Self.contribution(id: "c3", authorID: "author-1"),
        ])

        let visible = detail.excluding(authors: ["author-1"], contributions: [])

        #expect(visible.contributions.map(\.id) == ["c2"])
    }

    /// A takedown is about one contribution and not about its author, who may
    /// have perfectly good photographs on the same trail.
    @Test("a takedown removes that set and leaves the contributor's others")
    func takingOneDownLeavesTheRest() {
        let detail = Self.detail(own: 0, [
            Self.contribution(id: "c1", authorID: "author-1"),
            Self.contribution(id: "c2", authorID: "author-1"),
        ])

        let visible = detail.excluding(authors: [], contributions: ["c1"])

        #expect(visible.contributions.map(\.id) == ["c2"])
    }

    /// The reason this is a whole detail and not a filtered array. A set
    /// removed from the middle must close the gap: the strip pages by position
    /// and the map's pins carry the same numbers, so a hole would leave a pin
    /// opening its neighbour.
    @Test("the gallery and the pins renumber together once a set is hidden")
    func indexesCloseUpBehindAHiddenSet() {
        let detail = Self.detail(own: 1, [
            Self.contribution(id: "c1", authorID: "author-1", count: 2),
            Self.contribution(id: "c2", authorID: "author-2", count: 2),
        ])

        let visible = detail.excluding(authors: ["author-1"], contributions: [])

        #expect(visible.galleryPhotos.map(\.index) == [0, 1, 2])
        #expect(visible.galleryPhotos.map(\.fileURL) == [
            Self.url("own-0"), Self.url("c2-0"), Self.url("c2-1"),
        ])
        // The map draws from the other list, and the two are one answer.
        #expect(visible.previewPhotos.map(\.index) == visible.galleryPhotos.map(\.index))
    }

    /// A block is about somebody else's contribution and a takedown is about
    /// one record. Neither is a statement about the hike's own author, whose
    /// photographs are the four fields a reviewer edits — see
    /// `CommunityContributedGalleryTests` for why those must stay reachable.
    @Test("the hike author's own photographs are never touched")
    func theSubmissionsOwnPhotographsSurvive() {
        let detail = Self.detail(own: 2, [Self.contribution(id: "c1", authorID: "author-1")])

        let visible = detail.excluding(authors: ["author-1"], contributions: ["c1"])

        #expect(visible.contributions.isEmpty)
        #expect(visible.photoFileURLs == detail.photoFileURLs)
        #expect(visible.photosOnRecord == detail.photosOnRecord)
        #expect(visible.ownGalleryPhotos == detail.ownGalleryPhotos)
        #expect(visible.galleryPhotos == detail.ownGalleryPhotos)
    }
}
