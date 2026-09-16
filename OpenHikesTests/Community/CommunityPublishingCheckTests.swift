//
//  CommunityPublishingCheckTests.swift
//  OpenHikesTests
//
//  The half of the gate that has to go and look.
//
//  `CommunityPublishingEligibilityTests` covers the rules as a pure function.
//  This covers the part that needs the library: which hikes count as already
//  shared, that a hike is never compared with itself, and that the expensive
//  question is not asked of a hike already refused by a cheap one.
//
//  It also covers the one rule that lives nowhere else: **a retread can be
//  either answer**, and which one it is turns on whether the earlier hike has
//  actually been published. A submission still in the queue is not a listing —
//  nobody can open it, so photographs aimed at it would be invisible for as
//  long as it stayed unpublished and invisible for good if it were declined.
//  That distinction cannot be made by the pure rules next door, because it
//  needs the other hike's `communityListingID`.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community publishing check")
struct CommunityPublishingCheckTests {
    /// Twelve kilometres due north, dense enough that a sample of it is a
    /// sample of a walk rather than of four points.
    private static func line(
        eastOffset: Double = 0,
        meters: Double = 12_000
    ) -> [RouteCoordinate] {
        let baseLatitude = 47.6
        let baseLongitude = 12.87
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(baseLatitude * .pi / 180)
        return (0..<300).map { step in
            let along = meters * Double(step) / 299
            return RouteCoordinate(
                latitude: baseLatitude + along / metersPerDegreeLatitude,
                longitude: baseLongitude + eastOffset / metersPerDegreeLongitude
            )
        }
    }

    private static func hike(
        in context: ModelContext,
        title: String,
        route: [RouteCoordinate],
        submissionID: String? = nil,
        listingID: String? = nil
    ) -> Hike {
        Fixture.hike(in: context, title: title, route: route) { hike in
            hike.communitySubmissionID = submissionID
            hike.communityListingID = listingID
        }
    }

    @Test("a first walk in an empty library may be published")
    func firstWalk() async throws {
        let context = try Fixture.modelContext()
        let hike = Self.hike(in: context, title: "Ridge", route: Self.line())

        #expect(await CommunityPublishingCheck.eligibility(of: hike, in: context) == .eligible)
    }

    /// A hike is never compared with itself. Re-opening the form for a hike
    /// that has already been sent must not refuse it as a duplicate of its own
    /// submission — that state is the share form's `duplicateSection`, which
    /// is about amending a listing rather than about a second trail.
    @Test("a hike does not retrace itself")
    func neverItself() async throws {
        let context = try Fixture.modelContext()
        let hike = Self.hike(in: context, title: "Ridge", route: Self.line(), submissionID: "sub-1")

        #expect(await CommunityPublishingCheck.eligibility(of: hike, in: context) == .eligible)
    }

    /// The earlier hike is **published**, so the second walk's photographs
    /// have somewhere to go: onto the listing the first one became. The route
    /// still does not, which is the rule that has not changed.
    @Test("a second walk along a published trail offers its photographs to it")
    func retreadOfAPublishedHike() async throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(
            in: context,
            title: "Thumsee Ridge Traverse",
            route: Self.line(),
            submissionID: "sub-1",
            listingID: "listing-1"
        )
        // The same trail, twenty metres to one side — two honest recordings of
        // one path, not two paths.
        let again = Self.hike(in: context, title: "Ridge again", route: Self.line(eastOffset: 20))

        let eligibility = await CommunityPublishingCheck.eligibility(of: again, in: context)
        #expect(eligibility.reason == .retreads(title: "Thumsee Ridge Traverse"))
        // The *earlier* hike's listing and the earlier hike's name, because
        // that is the trail the pictures are joining.
        #expect(eligibility.photoTarget?.listingID == "listing-1")
        #expect(eligibility.photoTarget?.title == "Thumsee Ridge Traverse")
        // Their own hike, so there is nobody to credit as somebody else.
        #expect(eligibility.photoTarget?.authorName == nil)
    }

    /// A hike the hiker has *not* shared is not something the list has an
    /// entry for, so walking near it is not a duplicate of anything.
    @Test("a private hike in the library is not something to be a duplicate of")
    func unsharedHikesAreNotCandidates() async throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(in: context, title: "Private ridge", route: Self.line())
        let again = Self.hike(in: context, title: "Ridge again", route: Self.line(eastOffset: 20))

        #expect(await CommunityPublishingCheck.eligibility(of: again, in: context) == .eligible)
    }

    /// A submission still waiting for review counts. The listing it is about
    /// to become is the one a second copy would duplicate, and a reviewer
    /// reading two of the same walk is exactly what this is for.
    /// And it is still a plain **refusal**, which is the half that matters
    /// now: there is no listing yet, so there is nothing for a contribution to
    /// be attached to. Photographs aimed at a submission nobody can open would
    /// be invisible until a reviewer said yes, and gone for good if they said
    /// no.
    @Test("a submission awaiting review counts, and offers nothing to attach to")
    func awaitingReviewCounts() async throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(in: context, title: "Sent yesterday", route: Self.line(), submissionID: "sub-1")
        let again = Self.hike(in: context, title: "Same walk", route: Self.line())

        let eligibility = await CommunityPublishingCheck.eligibility(of: again, in: context)
        #expect(eligibility == .refused(.retreads(title: "Sent yesterday")))
        #expect(eligibility.photoTarget == nil)
    }

    /// A different trail in the same valley is a different trail.
    @Test("another walk nearby is not a duplicate")
    func nearbyIsNotDuplicate() async throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(in: context, title: "East ridge", route: Self.line(), submissionID: "sub-1")
        let west = Self.hike(in: context, title: "West ridge", route: Self.line(eastOffset: 600))

        #expect(await CommunityPublishingCheck.eligibility(of: west, in: context) == .eligible)
    }

    /// Provenance is answered before anything is fetched, which is why an
    /// import is refused as an import even when it also retraces a published
    /// hike — and why opening the form for one costs no pass over the library.
    @Test("an import is refused without consulting the library")
    func importsShortCircuit() async throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(in: context, title: "Thumsee", route: Self.line(), submissionID: "sub-1")
        let saved = Fixture.hike(in: context, title: "Thumsee", route: Self.line()) { hike in
            hike.importedFromListingID = "listing-1"
            hike.importedAuthorName = "Anna"
        }

        let eligibility = await CommunityPublishingCheck.eligibility(of: saved, in: context)
        #expect(eligibility.reason == .savedFromTheCommunity(author: "Anna"))
        // The listing it was saved from, not the published hike it also
        // happens to retrace: provenance is answered first and answers it
        // whole, which is what makes the library pass unnecessary.
        #expect(eligibility.photoTarget?.listingID == "listing-1")
    }

    /// A tripwire rather than a rule about the app.
    ///
    /// `Fixture.ridgeRoute` is 0.01° of latitude end to end, which is about
    /// 1.11 km — a hundred metres clear of the floor and no more. Every
    /// existing suite that shares a hike uses it, so a fixture trimmed or a
    /// floor raised would turn a dozen unrelated publisher tests red at once
    /// with nothing saying why. This is the one that says why.
    @Test("the shared route fixture clears the publishing floor")
    func fixtureClearsTheFloor() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(
            hike.distanceMeters >= CommunityPublishingEligibility.minimumDistanceMeters,
            """
            the shared fixture is \(hike.distanceMeters) m against a floor of \
            \(CommunityPublishingEligibility.minimumDistanceMeters) m
            """
        )
    }

    /// The fetch itself, on its own: what `alreadyShared` includes and what it
    /// leaves out.
    @Test("only hikes with a submission are candidates, and never the hike itself")
    func candidates() throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(in: context, title: "Sent", route: Self.line(), submissionID: "sub-1")
        _ = Self.hike(in: context, title: "Private", route: Self.line())
        let subject = Self.hike(in: context, title: "Subject", route: Self.line(), submissionID: "sub-2")

        let candidates = CommunityPublishingCheck.alreadyShared(in: context, excluding: subject)
        #expect(candidates.map(\.title) == ["Sent"])
        // Absent rather than blank, which is the distinction the whole retread
        // answer now turns on — see this file's header.
        #expect(candidates.map(\.listingID) == [nil])
    }

    /// The other half of that fetch: a published hike brings its listing with
    /// it, which is the id a contribution is aimed at. Read off the same row
    /// rather than looked up again, so the target and the title can never be
    /// about two different hikes.
    @Test("a published candidate carries the listing a contribution would use")
    func candidatesCarryTheirListing() throws {
        let context = try Fixture.modelContext()
        _ = Self.hike(
            in: context,
            title: "Sent",
            route: Self.line(),
            submissionID: "sub-1",
            listingID: "listing-1"
        )
        let subject = Self.hike(in: context, title: "Subject", route: Self.line())

        let candidates = CommunityPublishingCheck.alreadyShared(in: context, excluding: subject)
        #expect(candidates.map(\.listingID) == ["listing-1"])
    }
}
