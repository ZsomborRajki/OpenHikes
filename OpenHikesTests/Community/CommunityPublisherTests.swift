//
//  CommunityPublisherTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// What actually leaves the device when a hike is shared, and what is written
/// down afterwards.
@MainActor
@Suite("Community publisher")
struct CommunityPublisherTests {
    @Test("the route and the hike's own details go up")
    func draftCarriesTheRoute() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Pilis Ridge")
        let transport = StubCommunityTransport()

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport
        )

        #expect(outcome == .submitted)
        let draft = try #require(transport.recording.submissions.first)
        #expect(draft.title == "Pilis Ridge")
        #expect(draft.authorName == "Anna")
        #expect(draft.route.count == hike.route.count)
        #expect(draft.hikeID == hike.id)
    }

    /// The listing is found by where the walk *starts*, because a hiker
    /// searching near a place is looking for something to set off on.
    @Test("the submission is located at the trailhead")
    func draftStartsAtTheTrailhead() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()

        _ = await CommunityPublisher.share(hike, authorName: "", transport: transport)

        let draft = try #require(transport.recording.submissions.first)
        let start = try #require(draft.startCoordinate)
        #expect(start.latitude == hike.route.first?.latitude)
        #expect(start.longitude == hike.route.first?.longitude)
    }

    /// The ordering this file's header calls the contract: a share that failed
    /// must not leave the device believing the hike was sent, because nothing
    /// can ever correct that belief.
    @Test("a refused upload writes nothing down")
    func failedShareRecordsNothing() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()
        transport.submissionResult = .failure(.unreachable)

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport
        )

        #expect(outcome == .refused(.unreachable))
        #expect(hike.communitySubmissionID == nil)
    }

    @Test("an accepted upload is remembered on the hike")
    func acceptedShareIsRecorded() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()
        transport.submissionResult = .success("submission-42")

        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)

        #expect(hike.communitySubmissionID == "submission-42")
    }

    /// A hike with no route is refused before anything is encoded or uploaded,
    /// so a hiker never waits on a request that was never going to be taken.
    @Test("a hike with no route is refused without a request")
    func routelessHikeIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: [])
        let transport = StubCommunityTransport()

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport
        )

        #expect(outcome == .refused(.nothingToShare))
        #expect(transport.recording.submissions.isEmpty)
    }

    /// The store refusing the commit is not a failed share — the submission is
    /// real and cannot be recalled. What is lost is only this device's memory
    /// of it.
    @Test("a refused local commit is still a successful share")
    func refusedCommitStillShared() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport,
            save: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        #expect(outcome == .submitted)
    }
}
