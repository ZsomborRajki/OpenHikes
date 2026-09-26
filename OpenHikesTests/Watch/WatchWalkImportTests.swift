//
//  WatchWalkImportTests.swift
//  OpenHikesTests
//
//  What a walk from the watch becomes, and what a second copy of it does not.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

@Suite("Walks arriving from the watch")
struct WatchWalkImportTests {
    @Test("a walk becomes a hike carrying the watch's own session")
    func aWalkBecomesAHike() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()

        let outcome = await WatchWalkImport.store(walk, in: container)

        let hikeID = try #require(outcome.importedHikeID)
        let context = ModelContext(container)
        let saved = try Fixture.hike(hikeID, in: context)
        let hike = try #require(saved)
        #expect(hike.route.count == walk.fixes.count)
        #expect(hike.watchSessionID == walk.sessionID)
        #expect(hike.date == walk.startedAt)
        #expect(outcome.deservesReceipt)
    }

    @Test("the same walk arriving twice is recognised rather than duplicated")
    func arrivingTwiceKeepsOneHike() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()

        let first = await WatchWalkImport.store(walk, in: container)
        let second = await WatchWalkImport.store(walk, in: container)

        let hikeID = try #require(first.importedHikeID)
        #expect(second == .alreadyImported(hikeID))
        // And it still earns a receipt, which is the half that matters: a walk
        // this phone already has is a walk the watch is done with, and
        // withholding the receipt would leave it offering the transfer
        // forever.
        #expect(second.deservesReceipt)
        #expect(try Fixture.hikeCount(in: container) == 1)
    }

    @Test("a walk with one fix is a place rather than a walk, and is refused")
    func oneFixIsRefused() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk(fixCount: 1)

        let outcome = await WatchWalkImport.store(walk, in: container)

        #expect(outcome == .refused(.tooShort))
        // No receipt, so the watch keeps it — which for this one is moot, since
        // the watch refuses to send it. The rule is what is being pinned.
        #expect(!outcome.deservesReceipt)
        #expect(try Fixture.hikeCount(in: container) == 0)
    }

    @Test("a store that refuses the save leaves nothing behind and earns no receipt")
    func aRefusedSaveKeepsTheWalkOnTheWatch() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()

        let outcome = await WatchWalkImport.store(walk, in: container) { _ in
            throw Fixture.RefusedSave()
        }

        #expect(outcome == .refused(.notSaved))
        // The whole point of the failure: the watch is never told to let go.
        #expect(!outcome.deservesReceipt)
        #expect(try Fixture.hikeCount(in: container) == 0)
    }

    @Test(
        "a redelivery whose ledger read fails is refused rather than saved again",
        arguments: Fixture.LedgerRead.allCases
    )
    func aFailedLedgerReadIsNotAMiss(failing read: Fixture.LedgerRead) async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()
        let first = await WatchWalkImport.store(walk, in: container)
        let hikeID = try #require(first.importedHikeID)

        let second = await WatchWalkImport.store(
            walk,
            in: container,
            ledger: Fixture.ledger(failing: read)
        )

        // A read that failed is not a read that found nothing: the walk may
        // well be here already, so it is refused, and the save that would
        // otherwise follow is never reached.
        #expect(second == .refused(.notSaved))
        #expect(!second.deservesReceipt)
        #expect(try Fixture.hikeCount(in: container) == 1)

        // The control: once the store reads again, the same walk is
        // recognised, and earns the receipt that lets the watch let go.
        let third = await WatchWalkImport.store(walk, in: container)
        #expect(third == .alreadyImported(hikeID))
        #expect(try Fixture.hikeCount(in: container) == 1)
    }

    @Test("the ground a pause covered is marked, and is not counted as walked")
    func aPauseIsNotWalked() async throws {
        let container = try Fixture.modelContainer()
        // Two fixes a kilometre apart, the second marked as ending a pause.
        let walk = Fixture.pausedWalk()

        let outcome = await WatchWalkImport.store(walk, in: container)

        let hikeID = try #require(outcome.importedHikeID)
        let context = ModelContext(container)
        let saved = try Fixture.hike(hikeID, in: context)
        let hike = try #require(saved)
        #expect(hike.route.last?.boundary == .paused)
        // The straight line across the pause is roughly 1.1 km, and none of it
        // is the hiker's.
        #expect(hike.distanceMeters == 0)
    }

    @Test("the saved length is measured from the track, not taken from the watch")
    func theTrackIsWhatIsMeasured() async throws {
        let container = try Fixture.modelContainer()
        // A walk whose reported figure is nonsense, which is the only way to
        // tell the two apart: the fixes are the same either way.
        let walk = Fixture.walk(reportedDistanceMeters: 999_999)

        let outcome = await WatchWalkImport.store(walk, in: container)

        let hikeID = try #require(outcome.importedHikeID)
        let context = ModelContext(container)
        let saved = try Fixture.hike(hikeID, in: context)
        let hike = try #require(saved)
        #expect(hike.distanceMeters < 1000)
    }

    @Test("a walk along a trail is named after it; a free one is named after its day")
    func namingFollowsTheTrail() {
        #expect(
            HikeTitle.watchRecording(trailName: "Rinnkendlsteig", recordedAt: Fixture.start)
                == "Rinnkendlsteig"
        )
        #expect(
            HikeTitle.watchRecording(trailName: nil, recordedAt: Fixture.start)
                .hasPrefix("Watch Hike, ")
        )
        // A name that is only whitespace is no name, which is what
        // `HikeTitle.bounded` already decides for every other name in the app.
        #expect(
            HikeTitle.watchRecording(trailName: "   ", recordedAt: Fixture.start)
                .hasPrefix("Watch Hike, ")
        )
    }

    enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let latitude = 47.55
        static let longitude = 12.90

        struct RefusedSave: Error {}
        struct RefusedFetch: Error {}

        /// Which of the ledger's two reads a test makes fail.
        enum LedgerRead: CaseIterable, Sendable {
            case sessionLookup
            case hikeLookup
        }

        /// The store's own ledger, with one of its reads refused.
        static func ledger(failing read: LedgerRead) -> WatchWalkImport.Ledger {
            var ledger = WatchWalkImport.Ledger.store
            switch read {
            case .sessionLookup:
                ledger.recordedHikeID = { _, _ in throw RefusedFetch() }
            case .hikeLookup:
                ledger.hikeExists = { _, _ in throw RefusedFetch() }
            }
            return ledger
        }

        /// Steps of about 11 m due north, which is a walk rather than wander.
        static func walk(
            fixCount: Int = 5,
            reportedDistanceMeters: Double = 44
        ) -> WatchRecordedWalk {
            let fixes = (0..<fixCount).map { step in
                WatchRecordedFix(
                    latitude: latitude + Double(step) * 0.0001,
                    longitude: longitude,
                    timestamp: start.addingTimeInterval(Double(step) * 8),
                    horizontalAccuracy: 5,
                    elevationMeters: 600 + Double(step)
                )
            }
            return WatchRecordedWalk(
                sessionID: UUID(),
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(max(0, fixCount - 1)) * 8),
                distanceMeters: reportedDistanceMeters,
                activeSeconds: Double(max(0, fixCount - 1)) * 8,
                fixes: fixes
            )
        }

        static func pausedWalk() -> WatchRecordedWalk {
            WatchRecordedWalk(
                sessionID: UUID(),
                startedAt: start,
                endedAt: start.addingTimeInterval(3600),
                distanceMeters: 0,
                activeSeconds: 0,
                fixes: [
                    WatchRecordedFix(
                        latitude: latitude,
                        longitude: longitude,
                        timestamp: start,
                        horizontalAccuracy: 5
                    ),
                    WatchRecordedFix(
                        latitude: latitude + 0.01,
                        longitude: longitude,
                        timestamp: start.addingTimeInterval(3600),
                        horizontalAccuracy: 5,
                        resumesAfterPause: true
                    ),
                ]
            )
        }

        static func modelContainer() throws -> ModelContainer {
            try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        }

        static func hike(_ id: UUID, in context: ModelContext) throws -> Hike? {
            var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }

        static func hikeCount(in container: ModelContainer) throws -> Int {
            try ModelContext(container).fetchCount(FetchDescriptor<Hike>())
        }
    }
}

private extension WatchWalkImportOutcome {
    /// The hike this arrival is about, whichever of the two ways it got there.
    var importedHikeID: UUID? {
        switch self {
        case .imported(let id), .alreadyImported(let id): id
        case .refused: nil
        }
    }
}
