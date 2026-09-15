//
//  SeededCommunityTransportTests.swift
//  OpenHikesTests
//
//  The stand-in database the community UI suite is built on, checked here so
//  a broken seed reports in twenty seconds rather than as seventeen red
//  accessibility audits twenty minutes later.
//
//  ``SeededCommunityTransport`` is the one test double that does not live in a
//  test bundle: the UI suite drives the app from outside the process, so its
//  fixtures have to be inside the app — `#if DEBUG`, reached only by a launch
//  that names a scenario. That placement is what puts it out of reach of every
//  suite that could otherwise assert on it, and a fixture nothing asserts on
//  is a fixture whose failures are only ever read as failures of the screens
//  in front of it. A queue that answered `notPermitted` for the wrong scenario
//  would show up as *the review section is missing*, which is also what a
//  genuinely broken section looks like.
//
//  What is worth pinning down is the part the scenarios *mean*, not the
//  prose in them: which scenarios serve rows, that blocking is observable
//  because two of three listings share an author, that a preview's pins and
//  files still describe each other, and that the queue refuses rather than
//  empties. Titles and distances are asserted only where a scenario's
//  argument depends on them — that no two published titles share a word, so
//  a typed search proves something.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Short for ``SeededCommunityFixture``. Not `Fixture`, which this bundle
/// already uses for the shared route and container fixtures.
private typealias Seed = SeededCommunityFixture

@Suite("Seeded community transport")
struct SeededCommunityTransportTests {
    // MARK: Which launches get one

    /// The rule the whole file rests on: a transport is reached by naming a
    /// scenario and in no other way, so every launch that does not name one
    /// still gets `nil` and the real database stays untouched.
    @Test("only a named scenario produces a transport")
    func scenariosAreOptIn() {
        #expect(SeededCommunityTransport.Scenario(argument: nil) == nil)
        #expect(SeededCommunityTransport.Scenario(argument: "") == nil)
        #expect(SeededCommunityTransport.Scenario(argument: "Seeded") == nil)
        #expect(SeededCommunityTransport.Scenario(argument: "seeded") == .seeded)

        for scenario in SeededCommunityTransport.Scenario.allCases {
            #expect(SeededCommunityTransport.Scenario(argument: scenario.rawValue) == scenario)
        }
    }

    @Test("three scenarios serve rows, and one of those serves a queue")
    func scenarioCapabilities() {
        let serving = SeededCommunityTransport.Scenario.allCases.filter(\.servesListings)
        #expect(Set(serving) == [.seeded, .published, .reviewing])

        let queueing = SeededCommunityTransport.Scenario.allCases.filter(\.servesQueue)
        #expect(queueing == [.reviewing])
    }

    // MARK: Browsing

    @Test("a seeded database answers with all three hikes")
    func seededListingsAreServed() async throws {
        let listings = try await Seed.nearby(.seeded)
        #expect(listings.count == 3)
        #expect(
            Set(listings.map(\.title)) == [
                SeededCommunityTransport.ridgeTitle,
                SeededCommunityTransport.lakeTitle,
                SeededCommunityTransport.scrambleTitle,
            ]
        )
    }

    /// The shape blocking is readable through: two rows go and one stays, so
    /// an emptied list and an applied block cannot be confused.
    @Test("two of the three hikes share an author, and one does not")
    func blockingLeavesExactlyOneRow() async throws {
        let remaining = try await Seed.nearby(
            .seeded,
            excluding: [SeededCommunityTransport.blockableAuthorID]
        )
        #expect(remaining.count == 1)
        #expect(remaining.first?.title == SeededCommunityTransport.lakeTitle)
        #expect(remaining.first?.authorID == SeededCommunityTransport.otherAuthorID)
    }

    /// A typed search proves something only if the query cannot match the
    /// rows it is supposed to exclude.
    @Test("no two published titles share a word a search could match")
    func titlesAreSearchablyDistinct() async throws {
        let listings = try await Seed.nearby(.seeded)
        let words = listings.map { Set($0.title.lowercased().split(separator: " ")) }
        for (index, first) in words.enumerated() {
            for other in words[(index + 1)...] {
                #expect(first.isDisjoint(with: other))
            }
        }
    }

    @Test("a search matches on title, case-insensitively, and excludes blocks")
    func searchMatchesTitles() async throws {
        let transport = Seed.transport(.seeded)
        let hits = try await transport.listings(
            matching: "lakeside",
            limit: 50,
            excluding: []
        )
        #expect(hits.map(\.title) == [SeededCommunityTransport.lakeTitle])

        let blocked = try await transport.listings(
            matching: SeededCommunityTransport.ridgeTitle,
            limit: 50,
            excluding: [SeededCommunityTransport.blockableAuthorID]
        )
        #expect(blocked.isEmpty)

        let nothing = try await transport.listings(
            matching: "no hike is called this",
            limit: 50,
            excluding: []
        )
        #expect(nothing.isEmpty)
    }

    @Test("the empty scenario answers, with nothing in it")
    func emptyScenarioServesNoRows() async throws {
        #expect(try await Seed.nearby(.empty).isEmpty)
        let searched = try await Seed.transport(.empty)
            .listings(matching: SeededCommunityTransport.ridgeTitle, limit: 50, excluding: [])
        #expect(searched.isEmpty)
    }

    /// `unreachable` rather than `unavailable`, because *Try Again* is the
    /// control the failing scenario exists to put under a test.
    @Test("the failing scenario refuses every read the same way")
    func failingScenarioIsUnreachable() async {
        let transport = Seed.transport(.failing)
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await Seed.nearby(.failing)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await transport.listings(matching: "ridge", limit: 50, excluding: [])
        }
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await transport.outlines(for: SeededCommunityTransport.seededListings)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await transport.pendingSubmissions()
        }
    }

    // MARK: Outlines

    /// The round trip is the point: the map draws whatever survives the real
    /// encoder and decoder, so a seeded outline that would not survive it is
    /// the bug this would otherwise hide.
    @Test("an outline survives the encoder it is drawn through")
    func outlinesSurviveTheRoundTrip() async throws {
        let listings = try await Seed.nearby(.seeded)
        let outlines = try await Seed.transport(.seeded).outlines(for: listings)

        #expect(outlines.count == listings.count)
        for listing in listings {
            let outline = try #require(outlines[listing.id])
            #expect(outline.count >= 2, "a line needs two points to be drawn")
        }
    }

    @Test("a database with no rows in it has no outlines either")
    func emptyScenarioHasNoOutlines() async throws {
        let outlines = try await Seed.transport(.empty)
            .outlines(for: SeededCommunityTransport.seededListings)
        #expect(outlines.isEmpty)
    }

    // MARK: Opening a hike

    /// What the preview screen depends on. The pins and the files describe
    /// each other by index, and `photosOnRecord` is what decides whether a
    /// reviewer may rewrite the set at all.
    @Test("a downloaded hike's photographs are real files its pins agree with")
    func detailIsConsistent() async throws {
        let directory = try Seed.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listing = try #require(
            SeededCommunityTransport.seededListings
                .first { $0.title == SeededCommunityTransport.ridgeTitle }
        )
        let detail = try await Seed.transport(.seeded)
            .detail(for: listing, downloadingInto: directory)

        #expect(detail.isConsistent)
        #expect(detail.hasEveryPhoto)
        #expect(detail.photoFileURLs.count == SeededCommunityTransport.photographedCount)
        #expect(detail.route.count >= 2)
        #expect(detail.trackDescription?.isEmpty == false)

        for url in detail.photoFileURLs {
            let size = try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 0, "a photograph a real decode has to read")
        }
    }

    /// The other half of the browse list: one hike without pictures, so an
    /// import that carries none is still covered.
    @Test("a hike published without photographs downloads without any")
    func detailWithoutPhotographs() async throws {
        let directory = try Seed.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listing = try #require(
            SeededCommunityTransport.seededListings
                .first { $0.title == SeededCommunityTransport.lakeTitle }
        )
        let detail = try await Seed.transport(.seeded)
            .detail(for: listing, downloadingInto: directory)

        #expect(detail.photoFileURLs.isEmpty)
        #expect(detail.photoPins.isEmpty)
        #expect(detail.isConsistent)
    }

    /// A scenario with no database behind it has nothing to open, and says so
    /// with the failure a taken-down hike produces rather than a transport
    /// one — which is the sentence the preview's error state is written for.
    @Test("opening a hike from an empty database is a hike that is gone")
    func detailFromEmptyScenarioIsGone() async throws {
        let directory = try Seed.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let listing = try #require(SeededCommunityTransport.seededListings.first)
        await #expect(throws: CommunityFailure.noLongerAvailable) {
            _ = try await Seed.transport(.empty)
                .detail(for: listing, downloadingInto: directory)
        }
    }

    // MARK: Sharing

    @Test("submitting returns an id derived from the hike")
    func submitAnswersWithAnID() async throws {
        let hikeID = UUID()
        let id = try await Seed.transport(.seeded).submit(Seed.draft(hikeID: hikeID))
        #expect(id.contains(hikeID.uuidString))
    }

    /// The same refusal the real transport makes, in the same place: a hike
    /// with no route is nothing to publish.
    @Test("a hike with no route is refused before the database is reached")
    func submittingNothingIsRefused() async {
        await #expect(throws: CommunityFailure.nothingToShare) {
            _ = try await Seed.transport(.seeded).submit(Seed.draft(route: []))
        }
        // Refused for the same reason under the failing scenario too: the
        // route is checked before the database is asked anything.
        await #expect(throws: CommunityFailure.nothingToShare) {
            _ = try await Seed.transport(.failing).submit(Seed.draft(route: []))
        }
    }

    @Test("a broken database cannot be submitted to")
    func submittingToABrokenDatabaseFails() async {
        await #expect(throws: CommunityFailure.notSignedIn) {
            _ = try await Seed.transport(.failing).submit(Seed.draft())
        }
    }
}
