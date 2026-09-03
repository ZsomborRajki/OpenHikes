//
//  TrailBasemapRendererTests+Overlap.swift
//  OpenHikesTests
//
//  A user flicking through a list changes the selection faster than a render
//  pass finishes, so passes overlap by design. `TrailBasemapRenderer`
//  serializes but does not queue — it suspends at every snapshot, and another
//  call enters in that gap — so `inFlight` and `generation` are the whole of
//  what keeps the App Group container readable through a burst.
//
//  These are the tests the injected render boundary made possible. What an
//  overlap does depends entirely on *where* the older pass was suspended and
//  on what the newer one managed to do, and until the boundary was a closure
//  both of those were MapKit's to decide. `supersedingRenderer(...)` scripts
//  the interleaving instead, so each branch of the bookkeeping is reached on
//  purpose rather than hoped for.
//
//  `overlappingRefreshesLeaveAConsistentStore` is the exception and stays
//  unscripted: genuinely concurrent entry, asserted only through the
//  invariant, because asserting a winner there would be asserting a
//  scheduling accident.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Synchronization
import Testing

extension TrailBasemapRendererTests {
    /// Roughly 1 km of latitude — far enough that a pass for
    /// ``neighbouringTrail`` bounds to a region the older pass's manifest
    /// cannot be mistaken for, close enough to stay the same kind of walk.
    nonisolated private static let neighbourOffsetDegrees = 0.01

    /// A trail 1 km north of ``trail``, for the overlap tests: the second
    /// selection, arriving while the first is still rendering.
    nonisolated private static let neighbouringTrail: [SharedTrailSnapshot.CodableCoordinate] = trail.map { point in
        .init(latitude: point.latitude + neighbourOffsetDegrees, longitude: point.longitude)
    }

    /// Whether the pass that supersedes the one under test manages to render
    /// anything. Both are ordinary — the second selection lands while the
    /// device still has a connection, or after it has lost one — and they
    /// leave the older pass's already-written files to be reclaimed by two
    /// different mechanisms, which is the whole point of separating them.
    private enum NewerPassOutcome {
        case publishes
        case rendersNothing
    }

    /// A renderer that lets a whole second pass run inside the `await` of the
    /// older pass's `supersedeBefore`-th snapshot. That interleaving is what
    /// an actor permits and what `inFlight` and `generation` exist for, and
    /// nothing else in this suite can produce it deliberately: before the
    /// boundary was injectable, *when* a pass suspended was MapKit's to
    /// decide.
    private static func supersedingRenderer(
        newerHike: UUID,
        supersedeBefore renderCount: Int,
        newerPass outcome: NewerPassOutcome
    ) -> TrailBasemapRenderer {
        struct State {
            var renders = 0
            var insideNewerPass = false
        }
        let slot = Mutex<TrailBasemapRenderer?>(nil)
        let state = Mutex(State())

        let renderer = TrailBasemapRenderer { input in
            let (isNewerPass, shouldSupersede) = state.withLock { state -> (Bool, Bool) in
                guard !state.insideNewerPass else { return (true, false) }
                state.renders += 1
                return (false, state.renders == renderCount)
            }
            if isNewerPass {
                switch outcome {
                case .publishes: return rendered(for: input)
                case .rendersNothing: return nil
                }
            }

            if shouldSupersede, let renderer = slot.withLock({ $0 }) {
                state.withLock { $0.insideNewerPass = true }
                await renderer.refreshIfNeeded(hikeID: newerHike, polyline: neighbouringTrail)
                state.withLock { $0.insideNewerPass = false }
            }
            return rendered(for: input)
        }
        slot.withLock { $0 = renderer }
        return renderer
    }

    /// The selection changing while a pass is suspended. The newer pass wins
    /// outright — it publishes, and the older one recognises it has been
    /// overtaken and drops results it has already computed rather than
    /// overwriting a manifest for a trail nobody is looking at.
    ///
    /// Run at both the first snapshot and the second, because the older pass
    /// is in a different state at each: at the first it has written nothing
    /// and simply returns, at the second it is holding an image on disk that
    /// no manifest will ever name, and `pruneBasemapImages(keeping:)` in the
    /// newer pass is what reclaims it. The outcome has to be the same either
    /// way, which is what the file-set assertion says.
    @Test(
        "a superseded render cannot publish after the newer render",
        arguments: [1, 2]
    )
    func supersededRenderCannotPublish(supersedeBefore: Int) async throws {
        let olderHike = UUID()
        let newerHike = UUID()
        let renderer = Self.supersedingRenderer(
            newerHike: newerHike,
            supersedeBefore: supersedeBefore,
            newerPass: .publishes
        )

        await renderer.refreshIfNeeded(hikeID: olderHike, polyline: Self.trail)

        let published = try #require(SharedStore.loadBasemapSet(for: newerHike))
        #expect(published.coverage == UnitMercatorRect(bounding: Self.neighbouringTrail))
        #expect(SharedStore.loadBasemapSet(for: olderHike) == nil)
        #expect(
            Self.Container.fileNames == Set(published.images.map(\.fileName)),
            "the superseded pass left its partial write behind"
        )
        Self.expectConsistentStore(for: [olderHike, newerHike], "after overlapping renders")
    }

    /// The case the older pass's cleanup `defer` is the *only* answer to:
    /// superseded after it had written an image, by a pass that then rendered
    /// nothing itself — a trail selected on a good connection, and a second
    /// one selected after it dropped.
    ///
    /// Nothing else reclaims that image. The newer pass publishes no manifest,
    /// so it never prunes, and no manifest names the file, so every reader is
    /// blind to it. It is reclaimed by the next render that publishes or by
    /// the next deselect — neither of which a user who stops changing trails
    /// ever performs. Until then the bytes sit in the App Group container.
    ///
    /// So the assertion is an *empty* directory rather than a consistent one.
    /// `expectConsistentStore(for:_:)` would pass on the leak: an orphan that
    /// no manifest advertises is precisely what it checks for, and here there
    /// is no manifest left to contradict.
    @Test("a pass superseded by one that renders nothing still takes its own images back")
    func supersededRenderReclaimsItsOwnImages() async {
        let olderHike = UUID()
        let newerHike = UUID()
        let renderer = Self.supersedingRenderer(
            newerHike: newerHike,
            supersedeBefore: 2,
            newerPass: .rendersNothing
        )

        await renderer.refreshIfNeeded(hikeID: olderHike, polyline: Self.trail)

        #expect(SharedStore.loadBasemapSet(for: olderHike) == nil)
        #expect(SharedStore.loadBasemapSet(for: newerHike) == nil)
        #expect(Self.Container.fileNames.isEmpty, "the abandoned pass leaked the image it had written")
    }

    /// The unscripted case: four selections racing, with an `invalidate()`
    /// landing somewhere in the middle of them. Nothing about which pass wins
    /// is assertable — an actor gives mutual exclusion but no ordering across
    /// suspensions — so what is asserted is only the invariant the
    /// bookkeeping exists to preserve.
    ///
    /// This cost minutes of MapKit timeouts to run before the boundary was
    /// injectable, and is worth keeping now that it costs microseconds: it is
    /// the only test here whose interleaving is the scheduler's rather than
    /// this file's.
    @Test("overlapping refreshes never leave the store half-written")
    func overlappingRefreshesLeaveAConsistentStore() async {
        let renderer = TrailBasemapRenderer { input in Self.rendered(for: input) }
        let hikeIDs = (0..<4).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for (offset, hikeID) in hikeIDs.enumerated() {
                group.addTask {
                    await renderer.refreshIfNeeded(
                        hikeID: hikeID,
                        polyline: Self.trail.map { point in
                            .init(
                                latitude: point.latitude + Double(offset) / 100,
                                longitude: point.longitude
                            )
                        }
                    )
                }
            }
            group.addTask { await renderer.invalidate() }
        }

        Self.expectConsistentStore(for: hikeIDs, "after an interrupted burst")
    }

    /// The deselect path in `BackgroundTrailTracker`, at the moment that
    /// makes it hard: the trail is cleared while a pass is suspended at a
    /// snapshot, so the pass wakes holding results for a trail the user is no
    /// longer looking at. `generation` is what stops it resurrecting them.
    ///
    /// Distinct from a deselect *after* a pass finishes, which
    /// `invalidateRemovesTheManifestAndTheImages` covers from the store's
    /// side: there the render was legitimate and is being undone, here it
    /// must never reach disk at all.
    @Test("invalidation discards a render suspended at the snapshot boundary")
    func invalidationDiscardsSuspendedRender() async {
        let hikeID = UUID()
        let rendererSlot = Mutex<TrailBasemapRenderer?>(nil)
        let renderer = TrailBasemapRenderer { input in
            await rendererSlot.withLock({ $0 })?.invalidate()
            return Self.rendered(for: input)
        }
        rendererSlot.withLock { $0 = renderer }

        await renderer.refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)

        #expect(SharedStore.loadBasemapSet(for: hikeID) == nil)
        #expect(Self.Container.fileNames.isEmpty)
    }

    /// The sequential half of the same path: a render completes, and the
    /// trail it was for is cleared straight afterwards. Awaiting the render
    /// first is what makes this the ordered case rather than the racing one —
    /// here the store really must end up empty, images and manifest together.
    @Test("a completed render is still dropped by a later invalidate")
    func aCompletedRenderIsStillDroppedByInvalidate() async throws {
        let renderer = TrailBasemapRenderer { input in Self.rendered(for: input) }
        let hikeID = UUID()

        await renderer.refreshIfNeeded(hikeID: hikeID, polyline: Self.trail)
        try #require(SharedStore.loadBasemapSet(for: hikeID) != nil)

        await renderer.invalidate()

        #expect(SharedStore.loadBasemapSet(for: hikeID) == nil)
        #expect(Self.Container.fileNames.isEmpty)
    }
}
