//
//  CommunityPublishedPhotosTests.swift
//  OpenHikesTests
//
//  What a published listing is allowed to claim about its photographs, and
//  when the record's assets are rewritten to make that claim true.
//
//  The case worth the type is the incomplete download. A reviewer can publish
//  a submission whose photographs did not all arrive — the screen says so and
//  offers it — and the rewrite is withheld there, because it is built out of
//  the copies on this device and would delete the missing one for good. The
//  count used to be written as if the rewrite had happened anyway, so the row
//  promised fewer photographs than the record serves, and the uncounted one
//  stayed fetchable by anybody who opened the hike.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Published photo count")
struct CommunityPublishedPhotosTests {
    private func decision(
        onRecord: Int,
        downloaded: Int? = nil,
        removing: Set<Int> = []
    ) -> CommunityPublishedPhotos {
        CommunityPublishedPhotos(
            photosOnRecord: onRecord,
            downloaded: downloaded ?? onRecord,
            removing: removing
        )
    }

    @Test("a whole download with nothing struck off leaves the record alone")
    func nothingRemoved() {
        let photos = decision(onRecord: 3)

        #expect(photos.rewrite == .leaveTheRecordAlone, "there is nothing to rewrite it to")
        #expect(photos.count == 3)
    }

    @Test("a removal rewrites the record and counts what is left")
    func removalRewrites() {
        let photos = decision(onRecord: 3, removing: [1])

        #expect(photos.rewrite == .keepOnly([0, 2]))
        #expect(photos.count == 2)
    }

    @Test("striking every photograph off publishes a hike with none")
    func removingEverything() {
        let photos = decision(onRecord: 2, removing: [0, 1])

        #expect(photos.rewrite == .keepOnly([]))
        #expect(photos.count == 0)
    }

    /// The reported bug. The removal buttons are not drawn in this state, so
    /// `removing` is empty in the app — but the count was computed from the
    /// *downloaded* set either way, and wrote 2 onto a listing whose record
    /// serves 3.
    @Test("an incomplete download claims what the record has, not what arrived")
    func incompleteDownloadCountsTheRecord() {
        let photos = decision(onRecord: 3, downloaded: 2)

        #expect(photos.rewrite == .leaveTheRecordAlone, "the missing one would be deleted by a rewrite")
        #expect(
            photos.count == 3,
            "the record keeps every asset, so a listing saying 2 hides a photograph anybody can still fetch"
        )
    }

    /// And a removal struck off before the shortfall was known is refused the
    /// same way: the record is not rewritten, so the count cannot pretend it
    /// was.
    @Test("a removal on an incomplete download changes nothing")
    func removalOnAnIncompleteDownload() {
        let photos = decision(onRecord: 4, downloaded: 3, removing: [0])

        #expect(photos.rewrite == .leaveTheRecordAlone)
        #expect(photos.count == 4)
    }

    /// An index the strip never had says nothing about the record, so it
    /// cannot take a photograph off the count either — which is why the count
    /// is the size of the kept set rather than a subtraction.
    @Test("an index outside the downloaded set is ignored")
    func indexOutsideTheSet() {
        let photos = decision(onRecord: 2, removing: [0, 7])

        #expect(photos.rewrite == .keepOnly([1]))
        #expect(photos.count == 1)
    }

    @Test("a submission with no photographs publishes none")
    func noPhotographs() {
        let photos = decision(onRecord: 0)

        #expect(photos.rewrite == .leaveTheRecordAlone)
        #expect(photos.count == 0)
    }
}
