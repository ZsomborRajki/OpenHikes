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
//  what a name matches, what happens to an entity whose hike is gone, and that
//  Siri and the search field fold names by the same rule. That last one is the
//  point of ``HikeNameMatch`` existing — a trail findable by typing that is
//  not findable by saying it reads as Siri being broken.
//

import Foundation
@testable import OpenHikes
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

    @Test("a hike is found by a word from the middle of its name")
    func aNameMatchesWithoutBeingAnchored() throws {
        try insert(title: "North Ridge Trail")
        try insert(title: "Thumsee Loop")

        let found = try coordinator().finishedHikes(matchingName: "ridge")
        #expect(found.map(\.title) == ["North Ridge Trail"])
    }

    /// The whole reason the rule is shared: a name dictated to Siri and one
    /// typed on a German keyboard differ in exactly these ways.
    @Test("case and diacritics are folded away, as they are in the search field")
    func nameMatchingFoldsTheSameWayTheSearchFieldDoes() throws {
        try insert(title: "Zugspitze über den Stopselzieher")

        #expect(try coordinator().finishedHikes(matchingName: "ZUGSPITZE").count == 1)
        #expect(try coordinator().finishedHikes(matchingName: "uber").count == 1)
    }

    @Test("a name that starts with the query is ranked above one that merely contains it")
    func prefixMatchesComeFirst() throws {
        try insert(title: "Old Ridge Path")
        try insert(title: "Ridge Direct")

        let found = try coordinator().finishedHikes(matchingName: "ridge")
        #expect(found.map(\.title) == ["Ridge Direct", "Old Ridge Path"])
    }

    /// `HikeSearch` argues this at length for the sheet, and Siri has exactly
    /// the same problem: a renamed hike keeps its imported `title`, and the
    /// new name is the only one the hiker has ever seen.
    @Test("a renamed hike is found by the name the hiker gave it")
    func renamedHikesAreFoundByTheirNewName() throws {
        try insert(title: "2026-07-04 14:12") { hike in
            hike.customName = "Kalvarienberg"
        }

        #expect(try coordinator().finishedHikes(matchingName: "Kalvarienberg").count == 1)
        #expect(
            try coordinator().finishedHikes(matchingName: "2026-07-04").isEmpty,
            "the imported title is not a name anybody has seen"
        )
    }

    @Test("an empty query matches nothing rather than everything")
    func anEmptyQueryIsNotAWildcard() throws {
        try insert(title: "Thumsee Loop")

        #expect(try coordinator().finishedHikes(matchingName: "").isEmpty)
        #expect(try coordinator().finishedHikes(matchingName: "   ").isEmpty)
    }

    @Test("a recording in progress cannot be named")
    func aDraftIsNotNameable() throws {
        try insert(title: "Being walked now") { hike in
            hike.isRecording = true
        }

        #expect(try coordinator().finishedHikes(matchingName: "walked").isEmpty)
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
    func theEntityDescribesItself() throws {
        try insert(title: "Thumsee Loop", distanceMeters: 8400)
        let report = try #require(try coordinator().finishedHikes().first)

        let entity = HikeEntity(report)
        #expect(entity.name == "Thumsee Loop")
        #expect(entity.id == report.id)
        #expect(entity.distance.value == 8400)
    }

    @Test("suggestions are the most recent hikes, newest first")
    func suggestionsAreRecentFirst() throws {
        try insert(title: "Older", daysAgo: 3)
        try insert(title: "Newest", daysAgo: 1)
        try insert(title: "Middle", daysAgo: 2)

        let all = try coordinator().finishedHikes()
        #expect(all.map(\.title) == ["Newest", "Middle", "Older"])
    }

    // MARK: - Harness

    private lazy var now = Date(timeIntervalSince1970: 1_757_000_000)

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
