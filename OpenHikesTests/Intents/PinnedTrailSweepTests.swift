//
//  PinnedTrailSweepTests.swift
//  OpenHikesTests
//
//  The launch sweep keeps a snapshot and a map for every trail a placed widget
//  is pinned to, and WidgetKit's answer is its only evidence of which those
//  are. That answer can fail. Read as "nothing is pinned", a failure deleted
//  the snapshot a pinned widget draws its trail from while sparing the map
//  under it, and the widget drew its empty state until the next launch's
//  sweep (#995).
//
//  The answer is injected, and so is every write, for the reasons
//  `SharedHikeCatalogPublisher.PinnedTrailSweep` gives: the test host has no
//  placed widgets, and what is worth asserting is what the sweep does with
//  each answer.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Pinned trail sweep")
struct PinnedTrailSweepTests {
    /// What the sweep asked of the App Group, one entry per call.
    nonisolated struct Writes: Equatable, Sendable {
        var published: [UUID] = []
        var keptSnapshots: [Set<UUID>] = []
        var keptBasemaps: [Set<UUID>] = []
    }

    nonisolated final class WriteLog: Sendable {
        private let writes = Mutex(Writes())

        var recorded: Writes { writes.withLock { $0 } }

        func record(_ change: @Sendable (inout Writes) -> Void) {
            writes.withLock { change(&$0) }
        }
    }

    private static func sweep(
        answering answer: PinnedTrails,
        selected: Set<UUID>,
        into log: WriteLog
    ) -> SharedHikeCatalogPublisher.PinnedTrailSweep {
        SharedHikeCatalogPublisher.PinnedTrailSweep(
            pinnedTrails: { answer },
            selectedHikeIDs: { selected },
            publishTrail: { hikeID in log.record { $0.published.append(hikeID) } },
            pruneTrailSnapshots: { kept in log.record { $0.keptSnapshots.append(kept) } },
            pruneBasemaps: { kept in log.record { $0.keptBasemaps.append(kept) } }
        )
    }

    /// The report: no answer is not an empty answer. Publishing nothing is
    /// right, since every hike is not the alternative; deleting anything is
    /// not, because what a pinned widget draws from is on disk and nothing
    /// says it is no longer wanted.
    @Test("when WidgetKit cannot say what is pinned, nothing is published or pruned")
    func unknownPinsTouchNothing() async {
        let log = WriteLog()

        await SharedHikeCatalogPublisher.publishPinnedTrails(
            Self.sweep(answering: .unknown, selected: [UUID()], into: log)
        )

        #expect(log.recorded == Writes())
    }

    /// A known empty inventory is the case the prune exists for: only the
    /// selection's own files survive, snapshot and map alike.
    @Test("with nothing pinned, only the selected trail's snapshot and map are kept")
    func noPinsKeepOnlyTheSelection() async {
        let selected = UUID()
        let log = WriteLog()

        await SharedHikeCatalogPublisher.publishPinnedTrails(
            Self.sweep(answering: .known([]), selected: [selected], into: log)
        )

        #expect(log.recorded == Writes(keptSnapshots: [[selected]], keptBasemaps: [[selected]]))
    }

    @Test("a pinned trail is published and kept beside the selected one")
    func pinnedTrailsArePublishedAndKept() async {
        let pinned = UUID()
        let selected = UUID()
        let log = WriteLog()

        await SharedHikeCatalogPublisher.publishPinnedTrails(
            Self.sweep(answering: .known([pinned]), selected: [selected], into: log)
        )

        #expect(
            log.recorded == Writes(
                published: [pinned],
                keptSnapshots: [[pinned, selected]],
                keptBasemaps: [[pinned, selected]]
            )
        )
    }
}
