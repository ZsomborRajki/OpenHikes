//
//  CommunityReviewSessionTests.swift
//  OpenHikesTests
//
//  A review in progress through a turn of the phone (#1353).
//
//  The two review screens kept their decisions as their own `@State`, so the
//  screen a turn built in the other host started the review over: it
//  downloaded the submission again, put back the photographs struck off and
//  the title as sent, and forgot a decision already under way. These hold the
//  review to its route instead — kept by ``SheetPresentation`` while the
//  route is on the stack, ended when it leaves — and the screens that come up
//  for it to one download between them.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Community review session", .timeLimit(.minutes(1)))
struct CommunityReviewSessionTests {
    private static let correctedTitle = "Karwendelhaus, by the north side"

    @Test("a hike's review outlives a turn of the phone, and its downloads go with its route")
    func aHikesReviewFollowsItsRoute() async throws {
        let pending = CommunityPendingSubmission.stub()
        let route = SheetRoute.pendingSubmission(pending)
        let presentation = SheetPresentation()
        presentation.path = [route]
        let review = presentation.review(of: pending)
        #expect(review.titleDraft == pending.title, "the title starts as the one that was sent")
        review.titleDraft = Self.correctedTitle
        review.decisions.toggleRemoval(of: 1) { _ in /* nothing has arrived to show */ }
        let staging = try Self.download(into: review.decisions)

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.review(of: pending) === review)
            #expect(review.titleDraft == Self.correctedTitle, "the correction stays")
            #expect(review.decisions.removedPhotos == [1], "and so does the photograph struck off")
            #expect(!review.decisions.hasEnded && FileManager.default.fileExists(atPath: staging.path))
        }

        presentation.path = []
        #expect(review.decisions.hasEnded)
        await settleDelegateHop(until: "the downloads to go once nothing is using them") {
            !FileManager.default.fileExists(atPath: staging.path)
        }

        presentation.path = [route]
        let next = presentation.review(of: pending)
        #expect(next !== review, "opening it again is a new review")
        #expect(next.titleDraft == pending.title && next.decisions.removedPhotos.isEmpty)
    }

    @Test("a contribution's review outlives a turn of the phone, and its downloads go with its route")
    func aContributionsReviewFollowsItsRoute() async throws {
        let pending = CommunityPendingPhotos.stub()
        let route = SheetRoute.pendingPhotos(pending)
        let presentation = SheetPresentation()
        presentation.path = [route]
        let decisions = presentation.review(of: pending)
        decisions.toggleRemoval(of: 0) { _ in /* nothing has arrived to show */ }
        let staging = try Self.download(into: decisions)

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.review(of: pending) === decisions)
            #expect(decisions.removedPhotos == [0])
            #expect(!decisions.hasEnded)
        }

        // Taken off the stack by the decision landing, which empties the path.
        presentation.path = []
        #expect(decisions.hasEnded)
        await settleDelegateHop(until: "the downloads to go once nothing is using them") {
            !FileManager.default.fileExists(atPath: staging.path)
        }
        presentation.path = [route]
        #expect(presentation.review(of: pending) !== decisions)
    }

    /// A turn takes one screen away and brings another up for the same
    /// review, and the turn back to portrait can do that twice. Only the
    /// first one's question is a request; the others find it out, or its
    /// answer in, and put that answer back on the map.
    @Test("the screens that come up for a review ask for it once, and each shows the map what has arrived")
    func screensComingUpForAReviewAskOnce() async {
        let decisions = CommunityReviewDecisions<CommunityPhotoContribution>(listing: .stub())
        let gate = AsyncGate()
        let requests = RequestCount()
        let arriving = Self.contribution
        let download: @Sendable (URL) async -> CommunityPhotoContribution = { _ in
            await requests.add()
            await gate.wait()
            return arriving
        }
        var shown = 0

        decisions.begin(loading: download) { _ in shown += 1 }
        decisions.begin(loading: download) { _ in shown += 1 }
        await gate.open()
        await settleDelegateHop(until: "the contribution to arrive") { decisions.hasLoaded }
        #expect(await requests.count == 1, "the second screen waits for the first one's download")
        #expect(shown == 1)

        decisions.begin(loading: download) { _ in shown += 1 }
        #expect(shown == 2, "a screen coming up once it is in shows it on the map")
        #expect(await requests.count == 1)

        decisions.end()
        decisions.begin(loading: download) { _ in shown += 1 }
        #expect(await requests.count == 1, "nothing starts once the route has gone")
    }

    private static let contribution = CommunityPhotoContribution(
        id: "contribution-1",
        photoSubmissionID: "submission-1",
        authorName: "Aino",
        authorID: "author-1",
        publishedAt: Date(timeIntervalSince1970: 0),
        photoPins: [],
        photoFileURLs: []
    )

    /// Writes a photograph into the review's staging directory, as its
    /// download would have.
    private static func download<Subject>(into decisions: CommunityReviewDecisions<Subject>) throws -> URL {
        try FileManager.default.createDirectory(at: decisions.staging, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: decisions.staging.appending(path: "photo-0.jpeg"))
        return decisions.staging
    }
}

/// How many times the download was asked for, from whichever task asked.
private actor RequestCount {
    private(set) var count = 0

    func add() {
        count += 1
    }
}
