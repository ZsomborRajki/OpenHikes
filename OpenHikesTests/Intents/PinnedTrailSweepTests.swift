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
//  A pin is no proof its hike exists either. One deleted on another device
//  kept its snapshot for good, because every pin was kept whatever its read
//  found (#1378). `PinnedTrailSweepTests+Store.swift` drives the same sweep
//  through the real read, writer and App Group files.
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
        var reloads = 0
    }

    nonisolated final class WriteLog: Sendable {
        private let writes = Mutex(Writes())

        var recorded: Writes { writes.withLock { $0 } }

        func record(_ change: @Sendable (inout Writes) -> Void) {
            writes.withLock { change(&$0) }
        }
    }

    /// - Parameter gone: the pins whose hike the store no longer holds, which
    ///   publication answers by letting their files go.
    private static func sweep(
        answering answer: PinnedTrails,
        selected: Set<UUID>,
        into log: WriteLog,
        gone: Set<UUID> = []
    ) -> SharedHikeCatalogPublisher.PinnedTrailSweep {
        SharedHikeCatalogPublisher.PinnedTrailSweep(
            pinnedTrails: { answer },
            selectedHikeIDs: { selected },
            publishTrail: { hikeID in
                guard !gone.contains(hikeID) else { return .discard }
                log.record { $0.published.append(hikeID) }
                return .keep
            },
            pruneTrailSnapshots: { kept in log.record { $0.keptSnapshots.append(kept) } },
            pruneBasemaps: { kept in log.record { $0.keptBasemaps.append(kept) } },
            reloadWidgets: { log.record { $0.reloads += 1 } }
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

    /// The report: a widget pinned to a hike deleted elsewhere kept drawing
    /// its route, because the pin alone kept the files. A trail that is gone
    /// leaves the keep set, and the widgets redraw so the one pinned to it
    /// stops drawing the route now rather than at its next scheduled reload.
    @Test("a pinned hike that is gone loses its snapshot and map, and the widgets redraw")
    func goneHikesLoseTheirFiles() async {
        let gone = UUID()
        let pinned = UUID()
        let selected = UUID()
        let log = WriteLog()

        await SharedHikeCatalogPublisher.publishPinnedTrails(
            Self.sweep(answering: .known([gone, pinned]), selected: [selected], into: log, gone: [gone])
        )

        #expect(
            log.recorded == Writes(
                published: [pinned],
                keptSnapshots: [[pinned, selected]],
                keptBasemaps: [[pinned, selected]],
                reloads: 1
            )
        )
    }

    /// Selected as well as pinned, a hike that is gone still goes. The one
    /// selection whose files must stay is the trail the live feed holds, and
    /// publication answers that one by keeping it.
    @Test("a pinned hike that is gone goes even when it is also the selection")
    func aGoneSelectionGoesToo() async {
        let gone = UUID()
        let log = WriteLog()

        await SharedHikeCatalogPublisher.publishPinnedTrails(
            Self.sweep(answering: .known([gone]), selected: [gone], into: log, gone: [gone])
        )

        #expect(log.recorded == Writes(keptSnapshots: [[]], keptBasemaps: [[]], reloads: 1))
    }
}
