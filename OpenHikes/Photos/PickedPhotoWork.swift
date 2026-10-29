//
//  PickedPhotoWork.swift
//  OpenHikes
//
//  The two route-sized steps of filing photographs from the system picker,
//  and where they run.
//
//  Building the selection's ``HikePhotoSearchPlan`` indexes the route — its
//  timeline, its measured legs and, on every trail, a whole ``RouteProfile``,
//  because the picker projects a photograph's own position onto the line.
//  Placing one photograph against that plan can then project the camera's
//  position onto the whole route. ``PhotoDiscoveryWork`` moved the same plan
//  off the main actor for "Find Photos of This Hike" (#1119), but the picker
//  kept building its own synchronously in the picker's completion, and
//  awaiting a photograph's metadata moved only the read: the placement after
//  it ran back on the main actor, once per photo (#1189).
//
//  So both steps take plain values — a ``HikePhotoSearchPlan/SourceRead``,
//  the plan, the photograph's bytes — and run `@concurrent`, never in a bare
//  `Task`, which would inherit the caller's actor. The first reads the hike
//  as well, in a context of its own, because the read decodes the route and
//  hashes it (#1215). The hike is named on the main actor before the hop and
//  the photo stored on it after, so no model crosses.
//
//  The steps themselves are closures only so a suite can see which thread
//  they ran on: ``standard`` is the fetch, the plan and the placement as they
//  are, and nothing else ever replaces them.
//

import CoreLocation
import Foundation
import OpenHikesData
import SwiftData

nonisolated struct PickedPhotoWork: Sendable {
    /// Fetches the hike a selection reads, into the context the read made
    /// for it — ``HikePhotoSearchPlan/SourceRead/fetchHike(_:_:)``.
    let fetchHike: @Sendable (ModelContext, PersistentIdentifier) throws -> Hike?
    /// Builds the selection's plan, profile included, from what was read off
    /// the hike.
    let buildPlan: @Sendable (HikePhotoSearchPlan.Source) -> HikePhotoSearchPlan
    /// Places one photograph by what it says about itself —
    /// ``PickedPhotoPlacement/resolve(_:plan:fallback:now:)``.
    let place: @Sendable (PickedPhotoMetadata, HikePhotoSearchPlan?, CLLocationCoordinate2D?) -> PickedPhotoPlacement

    static let standard = Self(
        fetchHike: HikePhotoSearchPlan.SourceRead.fetchHike,
        buildPlan: { HikePhotoSearchPlan(source: $0, profilesRoute: true) },
        place: { metadata, plan, fallback in
            PickedPhotoPlacement.resolve(metadata, plan: plan, fallback: fallback)
        }
    )

    /// The plan a whole selection is placed against, read and built off the
    /// main actor.
    ///
    /// `nil` for a selection filed under a place, which names no hike — see
    /// ``PhotoCaptureController/Filing/pickerSearchSource`` — and for an
    /// import already cancelled: its caller stops before placing anything,
    /// so a route's worth of reading and indexing would be spent on no one.
    /// `nil` too for a hike the store no longer holds, which has no line to
    /// place a photograph on.
    @concurrent
    func plan(from read: HikePhotoSearchPlan.SourceRead?) async -> HikePhotoSearchPlan? {
        guard let read, !Task.isCancelled else { return nil }
        assertOffMainThread("Reading and indexing a hike's route for picked photos must stay off the main thread")
        return read.source(fetch: fetchHike).map(buildPlan)
    }

    /// Where one photograph belongs: its capture time and position read out
    /// of its bytes and placed against `plan`, both off the main actor.
    @concurrent
    func placement(
        of data: Data,
        plan: HikePhotoSearchPlan?,
        fallback: CLLocationCoordinate2D?
    ) async -> PickedPhotoPlacement {
        assertOffMainThread("Placing a picked photo must stay off the main thread")
        return place(PickedPhotoMetadata.read(data), plan, fallback)
    }
}

extension PhotoCaptureController.Filing {
    /// What a selection from the picker filed here is matched against, named
    /// now, on the hike's actor, for ``PickedPhotoWork/plan(from:)`` to read
    /// and index off it.
    ///
    /// `nil` for a selection filed under a place. The place is where its
    /// pictures are pinned, however well their clocks or cameras would match
    /// the walk — see ``PickedPhotoPlacement/resolve(_:plan:fallback:now:)``
    /// — so there is nothing to read off the hike and nothing to index.
    var pickerSearchSource: HikePhotoSearchPlan.SourceRead? {
        placeID == nil ? HikePhotoSearchPlan.SourceRead(hike) : nil
    }
}
