//
//  TrailBasemapRendererTests+Pinned.swift
//  OpenHikesTests
//
//  A widget pinned to a trail draws that trail whatever the app has selected,
//  so its map has to survive the selection moving on. It did not: the
//  container held one set, the selection's render replaced it, and a pinned
//  widget went on drawing its trail's line on a grey fill with the trail's
//  figures above it — the report this file answers.
//
//  The pinned set is injected rather than asked of WidgetKit, for the reason
//  the render boundary is: the test host has no placed widgets, and what is
//  worth asserting is what the renderer does with the answer.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Synchronization
import Testing

extension TrailBasemapRendererTests {
    /// Roughly 1 km north of ``trail``, so the second trail's set cannot be
    /// mistaken for the first's.
    nonisolated private static let northOffsetDegrees = 0.01

    nonisolated private static let trailToTheNorth: [SharedTrailSnapshot.CodableCoordinate] = trail.map { point in
        .init(latitude: point.latitude + northOffsetDegrees, longitude: point.longitude)
    }

    private static func renderer(
        pinned: PinnedTrails,
        render: TrailBasemapRenderer.Render? = nil
    ) -> TrailBasemapRenderer {
        TrailBasemapRenderer(
            render: render ?? { input in Self.rendered(for: input) },
            pinnedHikeIDs: { pinned }
        )
    }

    /// The report, end to end at the store: a trail pinned, another selected.
    @Test("a pinned trail keeps its map when another trail is selected")
    func pinnedMapSurvivesASelection() async throws {
        let pinned = UUID()
        let selected = UUID()
        let renderer = Self.renderer(pinned: .known([pinned]))

        await renderer.refreshPinned(hikeID: pinned, polyline: Self.trail)
        let pinnedSet = try #require(SharedStore.loadBasemapSet(for: pinned))
        await renderer.refreshIfNeeded(hikeID: selected, polyline: Self.trailToTheNorth)

        #expect(SharedStore.loadBasemapSet(for: pinned) == pinnedSet)
        #expect(SharedStore.loadBasemapSet(for: selected) != nil)
        Self.expectConsistentStore(for: [pinned, selected], "after selecting past a pinned trail")
    }

    /// The same trail reached the way the user reached it: selected first,
    /// pinned while selected, then left. Its set came from the selection's
    /// pass, and the next selection's prune is what has to know better.
    @Test("a trail's map outlives its selection once a widget is pinned to it")
    func selectedThenPinnedMapSurvives() async {
        let first = UUID()
        let second = UUID()
        let renderer = Self.renderer(pinned: .known([first]))

        await renderer.refreshIfNeeded(hikeID: first, polyline: Self.trail)
        await renderer.refreshIfNeeded(hikeID: second, polyline: Self.trailToTheNorth)

        #expect(SharedStore.loadBasemapSet(for: first) != nil)
        #expect(SharedStore.loadBasemapSet(for: second) != nil)
        Self.expectConsistentStore(for: [first, second], "after the selection left a pinned trail")
    }

    /// Deselection drops the selected trail's map and nothing pinned.
    @Test("deselecting spares a pinned trail's map")
    func deselectingSparesThePinnedMap() async {
        let pinned = UUID()
        let selected = UUID()
        let renderer = Self.renderer(pinned: .known([pinned]))
        await renderer.refreshPinned(hikeID: pinned, polyline: Self.trail)
        await renderer.refreshIfNeeded(hikeID: selected, polyline: Self.trailToTheNorth)

        await renderer.invalidate()

        #expect(SharedStore.loadBasemapSet(for: pinned) != nil)
        #expect(SharedStore.loadBasemapSet(for: selected) == nil)
        Self.expectConsistentStore(for: [pinned, selected], "after deselecting beside a pinned trail")
    }

    /// WidgetKit not answering is not the same as nothing being pinned. A
    /// set nothing draws costs bytes until the next prune that can tell; a
    /// pinned one deleted on the guess costs a grey widget and four renders.
    @Test("when the pinned trails are unknown, no other trail's map is dropped")
    func unknownPinsDropNothing() async {
        let earlier = UUID()
        let later = UUID()
        let renderer = Self.renderer(pinned: .unknown)

        await renderer.refreshIfNeeded(hikeID: earlier, polyline: Self.trail)
        await renderer.refreshIfNeeded(hikeID: later, polyline: Self.trailToTheNorth)
        await renderer.invalidate()

        #expect(SharedStore.loadBasemapSet(for: earlier) != nil)
        #expect(SharedStore.loadBasemapSet(for: later) != nil)
        Self.expectConsistentStore(for: [earlier, later], "after pruning blind")
    }

    /// The launch that exercises both lanes at once: the sweep rendering a
    /// pinned trail while the restored selection renders — and, here, is
    /// deselected — inside the pinned pass's first snapshot. Neither is a
    /// reason for the pinned pass to give up.
    @Test("a pinned render is not overtaken by the selection or by a deselection")
    func pinnedRenderIsNotOvertaken() async throws {
        let pinned = UUID()
        let selected = UUID()
        let slot = Mutex<TrailBasemapRenderer?>(nil)
        let interrupted = Mutex(false)
        let renderer = Self.renderer(pinned: .known([pinned])) { input in
            let isFirst = interrupted.withLock { done in
                defer { done = true }
                return !done
            }
            if isFirst, let renderer = slot.withLock({ $0 }) {
                await renderer.refreshIfNeeded(hikeID: selected, polyline: Self.trailToTheNorth)
                await renderer.invalidate()
            }
            return Self.rendered(for: input)
        }
        slot.withLock { $0 = renderer }

        await renderer.refreshPinned(hikeID: pinned, polyline: Self.trail)

        let published = try #require(SharedStore.loadBasemapSet(for: pinned))
        #expect(
            Set(published.images.map { Self.Image($0.variant, $0.appearance) }) == Set(Self.everyImage)
        )
        #expect(SharedStore.loadBasemapSet(for: selected) == nil)
        Self.expectConsistentStore(for: [pinned, selected], "after a selection inside a pinned render")
    }

    /// The sweep's prune: what it names stays, everything else goes.
    @Test("the sweep's prune keeps the trails it names and drops the rest")
    func sweepPruneKeepsNamedTrails() async {
        let kept = UUID()
        let dropped = UUID()
        let renderer = Self.renderer(pinned: .known([kept, dropped]))
        await renderer.refreshPinned(hikeID: kept, polyline: Self.trail)
        await renderer.refreshPinned(hikeID: dropped, polyline: Self.trailToTheNorth)

        await renderer.prune(keeping: [kept])

        #expect(SharedStore.loadBasemapSet(for: kept) != nil)
        #expect(SharedStore.loadBasemapSet(for: dropped) == nil)
        Self.expectConsistentStore(for: [kept, dropped], "after the sweep's prune")
    }
}
