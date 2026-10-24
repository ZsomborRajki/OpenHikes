//
//  CommunitySharePhotoTallyTests.swift
//  OpenHikesTests
//
//  The number both publishing forms put in front of a hiker before they send.
//
//  It is worth a suite of its own because it is the one place the two forms
//  are *not* allowed to differ. ``CommunityShareSheet`` and
//  ``CommunityPhotoShareSheet`` are deliberately different screens asking for
//  different things — see the second's header — but the count under the strip
//  has to be the count that goes, on both, and it used to be worked out twice.
//
//  Neither form can be asked this directly: both are SwiftUI bodies, evaluated
//  by `OpenHikesUITests` alone and excluded from the coverage floor for that
//  reason. Extracting the arithmetic is what put it back within reach of a
//  suite that runs in CI, which is most of the point of extracting it.
//
//  Nothing here touches the disk. That is the shape of the type rather than a
//  shortcut: `sendableCount` is an *input*, because the answer comes from a
//  `.task` the view owns, and every case below is about what the tally does
//  with an answer it has been given — or with not having one yet.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community share photo tally")
struct CommunitySharePhotoTallyTests {
    /// A tally built the way both forms build one: from the strip's list,
    /// read once.
    private func tally(of hike: Hike, excluding excluded: Set<UUID>, sendableCount: Int?) -> CommunitySharePhotoTally {
        CommunitySharePhotoTally(
            offered: CommunityPublisher.shareablePhotos(of: hike),
            excluding: excluded,
            sendableCount: sendableCount
        )
    }

    /// Before the disk has answered, the capped row count is the best guess
    /// available — and it is a guess about *rows*, which is why the form holds
    /// its Send button until ``hasCounted``.
    @Test("with no answer from the disk, the rows are the estimate")
    func rowsAreTheEstimateUntilTheDiskAnswers() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        for _ in 0..<3 { hike.photos.append(HikePhoto()) }

        let tally = tally(of: hike, excluding: [], sendableCount: nil)

        #expect(tally.includedCount == 3)
        #expect(tally.count == 3)
        #expect(!tally.hasCounted)
        #expect(tally.hasSomethingToSend)
        // Nothing to subtract from yet, so nothing is claimed to be missing.
        #expect(tally.unsendableCount == 0)
    }

    /// Once it has, that is the number that will really go.
    @Test("the disk's answer replaces the estimate")
    func theDisksAnswerWins() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        for _ in 0..<5 { hike.photos.append(HikePhoto()) }

        let tally = tally(of: hike, excluding: [], sendableCount: 2)

        #expect(tally.count == 2)
        #expect(tally.hasCounted)
        // Rows are not files: three of this hike's pictures are on the device
        // they were added on, and the form says so rather than letting the
        // hiker read a shrunken number as the app having lost them.
        #expect(tally.unsendableCount == 3)
    }

    /// Struck off the strip is struck off the count, on both forms.
    @Test("an excluded photograph is not counted")
    func exclusionsComeOffTheCount() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photos = (0..<4).map { _ in HikePhoto() }
        for photo in photos { hike.photos.append(photo) }

        let tally = tally(
            of: hike,
            excluding: [photos[0].id, photos[1].id],
            sendableCount: nil
        )

        #expect(tally.includedCount == 2)
        #expect(tally.count == 2)
    }

    /// The cap is applied *after* the exclusions, which is the difference
    /// between choosing a full ``CommunityPublisher/maximumPhotos`` and
    /// getting one fewer than that.
    @Test("the cap is applied after the exclusions, so striking one off lets another in")
    func theCapComesAfterTheExclusions() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photos = (0..<(CommunityPublisher.maximumPhotos + 4)).map { _ in HikePhoto() }
        for photo in photos { hike.photos.append(photo) }

        let full = tally(of: hike, excluding: [], sendableCount: nil)
        #expect(full.includedCount == CommunityPublisher.maximumPhotos + 4)
        #expect(full.count == CommunityPublisher.maximumPhotos)

        // Striking one off leaves more than the cap still ticked, so the
        // number that goes does not move: the next picture takes the slot.
        let trimmed = tally(
            of: hike,
            excluding: [photos[0].id],
            sendableCount: nil
        )
        #expect(trimmed.count == CommunityPublisher.maximumPhotos)
    }

    /// A hike saved from the community carries its author's pictures too, and
    /// none of those is going anywhere — the strip does not draw them and the
    /// upload does not take them, so the count must not include them.
    @Test("somebody else's photographs are not this hiker's to send")
    func importedPhotographsAreNotCounted() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.photos.append(HikePhoto())
        hike.photos.append(HikePhoto(importedFromListingID: "listing-1"))
        // A `<wpt>` out of an imported file: a place on the trail with no
        // picture behind it at all.
        hike.photos.append(HikePhoto(isPlaceOnly: true))

        let tally = tally(of: hike, excluding: [], sendableCount: nil)

        #expect(tally.includedCount == 1)
    }

    /// The ordinary state of a trail somebody saved and has not yet walked
    /// with a camera. It reaches the form legitimately, so the empty case is a
    /// sentence rather than a failure — and the form asks this to know which.
    @Test("a hike with nothing to send says so")
    func nothingToSend() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let unasked = tally(of: hike, excluding: [], sendableCount: nil)
        #expect(!unasked.hasSomethingToSend)

        // And the case that only the files can report: rows the disk cannot
        // back, on the device that is not the one they were added on.
        hike.photos.append(HikePhoto())
        let asked = tally(of: hike, excluding: [], sendableCount: 0)
        #expect(!asked.hasSomethingToSend)
        #expect(asked.unsendableCount == 1)
    }

    /// The forms now read the strip's list once a pass and build the tally,
    /// and the contribution form's already-sent count, from that one array
    /// rather than each asking ``CommunityPublisher/ownPhotos(of:)`` for a
    /// fresh sort. That is only the same answer if the strip's list is the
    /// hiker's own photographs reordered and nothing else, so this pins it on
    /// a hike holding every kind of row the gate tells apart.
    @Test("the strip's list counts the same as the hiker's own photographs, on a mixed hike")
    func theStripsListCountsLikeTheOwnPhotos() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let spot = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Later photographs first, and anchored ones in between, so the
        // strip's order differs from the hike's.
        let unanchored = HikePhoto(capturedAt: start)
        let anchored = HikePhoto(capturedAt: start.addingTimeInterval(60), coordinate: spot)
        var sent = HikePhoto(capturedAt: start.addingTimeInterval(120))
        sent.sentToCommunityAt = start.addingTimeInterval(3600)
        let sentAnchored = {
            var photo = HikePhoto(capturedAt: start.addingTimeInterval(180), coordinate: spot)
            photo.sentToCommunityAt = start.addingTimeInterval(3600)
            return photo
        }()
        hike.photos = [
            sentAnchored,
            HikePhoto(importedFromListingID: "listing-1"),
            sent,
            HikePhoto(isPlaceOnly: true),
            anchored,
            unanchored,
        ]

        let own = CommunityPublisher.ownPhotos(of: hike)
        let offered = CommunityPublisher.shareablePhotos(of: hike)
        #expect(offered.map(\.id) != own.map(\.id), "precondition: the strip reorders")
        #expect(Set(offered.map(\.id)) == Set(own.map(\.id)))
        #expect(offered.count == own.count)

        let excluded: Set<UUID> = [sent.id, anchored.id]
        let fromStrip = CommunitySharePhotoTally(offered: offered, excluding: excluded, sendableCount: nil)
        let fromOwn = CommunitySharePhotoTally(offered: own, excluding: excluded, sendableCount: nil)
        #expect(fromStrip.includedCount == 2)
        #expect(fromStrip.includedCount == fromOwn.includedCount)
        #expect(fromStrip.count == fromOwn.count)
        #expect(fromStrip.hasSomethingToSend == fromOwn.hasSomethingToSend)

        let answered = CommunitySharePhotoTally(offered: offered, excluding: excluded, sendableCount: 1)
        #expect(answered.count == 1)
        #expect(answered.unsendableCount == 1)

        // What the contribution form says is already up there, struck off.
        let alreadySent = { (photos: [HikePhoto]) in
            photos.count { $0.hasBeenSentToCommunity && excluded.contains($0.id) }
        }
        #expect(alreadySent(offered) == 1)
        #expect(alreadySent(offered) == alreadySent(own))
    }

    /// Number-neutral after the count, the rule the rest of this feature's
    /// wording follows: one photograph reads as written English rather than as
    /// a template with a 1 in it.
    @Test("the sentence about the pictures staying behind reads for one and for many")
    func theSentenceIsNumberNeutral() {
        let one = CommunitySharePhotoTally.onAnotherDevice(count: 1)
        #expect(one.hasPrefix("One of this hike’s photos is"))
        #expect(!one.contains("1 of"))

        let many = CommunitySharePhotoTally.onAnotherDevice(count: 4)
        #expect(many.hasPrefix("4 of this hike’s photos are"))
    }
}
