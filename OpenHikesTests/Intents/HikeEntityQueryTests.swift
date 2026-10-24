//
//  HikeEntityQueryTests.swift
//  OpenHikesTests
//
//  Naming a trail. Every intent in the app used to be parameterless, so Siri
//  could be told to start, pause, resume or stop *the* recording and asked
//  about *the current* hike, *today's* distance and *the last* one — but a
//  hiker could never say which walk they meant.
//
//  `AppEntity` conformance itself is the system's to exercise; what is
//  asserted here is everything under it, which is where the behaviour lives:
//  which name a hike answers to, and what happens to an entity whose hike is
//  gone.
//
//  A name is matched the way Siri and the pickers match it: against the
//  catalogue the app publishes to the App Group, through
//  ``SharedHikeCatalog/hikes(matching:)``. That is the only name match
//  ``HikeEntityQuery`` makes, so a test of any other matcher would pass
//  whatever Siri did (#1029). The match itself is pinned beside it, in
//  `SharedHikeCatalogTests`: a word from anywhere in a name finds it, case
//  and accents fold but width does not, the matches come in the catalogue's
//  order rather than prefix first, and a blank query is every hike. What is
//  pinned here is what only the app can get wrong — which name each hike is
//  published under, and which hikes are published at all.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

@Suite("Hike entity query")
final class HikeEntityQueryTests {
    private let container: ModelContainer
    private let context: ModelContext
    // periphery:ignore - as in `HikeIntentQueryTests`.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    // MARK: - Naming a hike

    /// `HikeSearch` argues this at length for the sheet, and Siri has exactly
    /// the same problem: a renamed hike keeps its imported `title`, and the
    /// new name is the only one the hiker has ever seen.
    @Test("a renamed hike is found by the name the hiker gave it")
    func renamedHikesAreFoundByTheirNewName() async throws {
        try insert(title: "2026-07-04 14:12") { hike in
            hike.customName = "Kalvarienberg"
        }
        let catalog = try await publishedCatalog()

        #expect(catalog.hikes(matching: "Kalvarienberg").map(\.name) == ["Kalvarienberg"])
        #expect(
            catalog.hikes(matching: "2026-07-04").isEmpty,
            "the imported title is not a name anybody has seen"
        )
    }

    /// Asked of a blank query as well as of a word from its name, because a
    /// blank query is every published hike: the draft has to be missing from
    /// the catalogue, not merely fail to match.
    @Test("a recording in progress cannot be named")
    func aDraftIsNotNameable() async throws {
        try insert(title: "Being walked now") { hike in
            hike.isRecording = true
        }
        try insert(title: "Thumsee Loop")
        let catalog = try await publishedCatalog()

        #expect(catalog.hikes(matching: "walked").isEmpty)
        #expect(catalog.hikes(matching: "").map(\.name) == ["Thumsee Loop"])
    }

    // MARK: - Resolving an identifier

    @Test("identifiers resolve in the order they were asked for")
    func identifiersKeepTheirOrder() throws {
        let first = try insert(title: "First")
        let second = try insert(title: "Second")

        let found = try coordinator().finishedHikes(withIDs: [second, first])
        #expect(found.map(\.title) == ["Second", "First"])
    }

    /// An entity outliving its hike is ordinary — a shortcut built last month,
    /// a Spotlight result for a walk since deleted. Resolving a *set* skips
    /// it, because the right answer is the ones that still exist.
    @Test("an identifier for a deleted hike is skipped rather than failing the batch")
    func aMissingIdentifierIsSkipped() throws {
        let kept = try insert(title: "Still here")

        let found = try coordinator().finishedHikes(withIDs: [UUID(), kept, UUID()])
        #expect(found.map(\.title) == ["Still here"])
    }

    /// Asking about *one* named hike is the opposite case: the hiker asked
    /// about a specific walk, and silence would be the wrong answer.
    @Test("asking about one hike that is gone says so")
    func oneMissingHikeIsReported() {
        #expect(throws: HikeIntentFailure.noHikesYet) {
            try coordinator().finishedHike(withID: UUID())
        }
    }

    // MARK: - What the entity carries

    @Test("the entity carries the name the hiker sees and a subtitle under it")
    func theEntityDescribesItself() async throws {
        try insert(title: "Thumsee Loop", distanceMeters: 8400)
        let report = try #require(try await coordinator().finishedHikes().first)

        let entity = HikeEntity(report)
        #expect(entity.name == "Thumsee Loop")
        #expect(entity.id == report.id)
        #expect(entity.distance.value == 8400)
    }

    @Test("suggestions are the most recent hikes, newest first")
    func suggestionsAreRecentFirst() async throws {
        try insert(title: "Older", daysAgo: 3)
        try insert(title: "Newest", daysAgo: 1)
        try insert(title: "Middle", daysAgo: 2)

        let all = try await coordinator().finishedHikes()
        #expect(all.map(\.title) == ["Newest", "Middle", "Older"])
    }

    // MARK: - Harness

    private lazy var now = Date(timeIntervalSince1970: 1_757_000_000)

    /// What the app writes to the App Group for ``HikeEntityQuery`` to read:
    /// the library the publisher's sweep reads, built into a catalogue by the
    /// publisher's own function but kept in memory, so no suite writes the
    /// container that a running widget reads.
    private func publishedCatalog() async throws -> SharedHikeCatalog {
        SharedHikeCatalogPublisher.catalog(from: try await coordinator().finishedHikes())
    }

    private func coordinator() -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: StubRecordingLocationSource(),
            defaults: UserDefaults(
                suiteName: "hike-entity-query-\(UUID().uuidString)"
            ) ?? .standard,
            powerMonitor: PowerStateMonitor(
                read: { PowerState() },
                observesNotifications: false
            ),
            journalDirectory: nil,
            automaticallyRecovers: false
        )
        recorder = instance
        return HikeIntentCoordinator(
            recorder: instance,
            container: container,
            clock: { [now] in now }
        )
    }

    /// Saved rather than inserted, for the reason ``HikeIntentQueryTests``
    /// gives: the coordinator answers through a fresh `ModelContext`.
    @discardableResult private func insert(
        title: String,
        daysAgo: Int = 0,
        distanceMeters: Double = 1000,
        configure: (Hike) -> Void = { _ in /* no-op */ }
    ) throws -> UUID {
        let hike = Hike(title: title, distanceMeters: distanceMeters)
        context.insert(hike)
        hike.date = now.addingTimeInterval(-Double(daysAgo) * 24 * 3600)
        configure(hike)
        try context.save()
        return hike.id
    }
}
