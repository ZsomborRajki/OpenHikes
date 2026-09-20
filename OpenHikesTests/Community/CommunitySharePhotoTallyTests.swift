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

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community share photo tally")
struct CommunitySharePhotoTallyTests {
    /// Before the disk has answered, the capped row count is the best guess
    /// available — and it is a guess about *rows*, which is why the form holds
    /// its Send button until ``hasCounted``.
    @Test("with no answer from the disk, the rows are the estimate")
    func rowsAreTheEstimateUntilTheDiskAnswers() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        for _ in 0..<3 { hike.photos.append(HikePhoto()) }

        let tally = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: nil)

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

        let tally = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: 2)

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

        let tally = CommunitySharePhotoTally(
            hike: hike,
            excluding: [photos[0].id, photos[1].id],
            sendableCount: nil
        )

        #expect(tally.includedCount == 2)
        #expect(tally.count == 2)
    }

    /// The cap is applied *after* the exclusions, which is the difference
    /// between choosing twelve and getting whichever eleven were left over.
    @Test("the cap is applied after the exclusions, so striking one off lets another in")
    func theCapComesAfterTheExclusions() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photos = (0..<(CommunityPublisher.maximumPhotos + 4)).map { _ in HikePhoto() }
        for photo in photos { hike.photos.append(photo) }

        let full = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: nil)
        #expect(full.includedCount == CommunityPublisher.maximumPhotos + 4)
        #expect(full.count == CommunityPublisher.maximumPhotos)

        // Striking one off leaves more than the cap still ticked, so the
        // number that goes does not move: the next picture takes the slot.
        let trimmed = CommunitySharePhotoTally(
            hike: hike,
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

        let tally = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: nil)

        #expect(tally.includedCount == 1)
    }

    /// The ordinary state of a trail somebody saved and has not yet walked
    /// with a camera. It reaches the form legitimately, so the empty case is a
    /// sentence rather than a failure — and the form asks this to know which.
    @Test("a hike with nothing to send says so")
    func nothingToSend() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let unasked = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: nil)
        #expect(!unasked.hasSomethingToSend)

        // And the case that only the files can report: rows the disk cannot
        // back, on the device that is not the one they were added on.
        hike.photos.append(HikePhoto())
        let asked = CommunitySharePhotoTally(hike: hike, excluding: [], sendableCount: 0)
        #expect(!asked.hasSomethingToSend)
        #expect(asked.unsendableCount == 1)
    }

    /// Number-neutral after the count, the rule the rest of this feature's
    /// wording follows: one photograph reads as written English rather than as
    /// a template with a 1 in it.
    @Test("the sentence about the pictures staying behind reads for one and for many")
    func theSentenceIsNumberNeutral() {
        let one = CommunitySharePhotoTally.onAnotherDevice(count: 1)
        #expect(one.hasPrefix("One of this hike's photos is"))
        #expect(!one.contains("1 of"))

        let many = CommunitySharePhotoTally.onAnotherDevice(count: 4)
        #expect(many.hasPrefix("4 of this hike's photos are"))
    }
}
