//
//  TrailDraftSave.swift
//  OpenHikes
//
//  Turning the drawn line into a hike.
//
//  **A saved trail is an ordinary ``Hike``**, which is the decision the whole
//  feature rests on: no new top-level entity, and so no parallel path through
//  the map, the library, the widget, GPX export or community publishing. Every
//  one of those goes on working with nothing added to it, and *Follow This
//  Trail* works on a drawn trail the day it is saved.
//
//  The consequence, stated rather than discovered: a drawn trail is the same
//  row a GPX import writes, plus what it was drawn from for *Edit Route* (see
//  ``DrawnRoute``), and its `date` is the day it was made rather than a day it
//  was walked. That is consistent — an imported trail is also a line somebody
//  drew elsewhere — and there is deliberately no *planned* flag, because
//  telling a plan from a walk takes none. The library's totals count a hike
//  as walked only when its route carries a clock, and a drawn line carries
//  none, so the trail itself never counts. Its walks count instead, each by
//  what it covered and on the day it started, less whatever part of its time
//  a counted hike's clock also covers, which that hike has counted already.
//  ``LibraryTotals`` owns that rule.
//
//  Two points is the floor, and it is a refusal rather than a disabled button
//  alone: one point is a place, and a `Hike` whose route is a single
//  coordinate has no length, no profile and nothing to draw. **The places
//  marked along it do not count towards that floor and cannot rescue a draft
//  below it**, which is the same distinction everywhere else in this feature:
//  a place is a spot on the ground beside a trail, not part of one, and a
//  saved hike with no route is not a hike whatever is marked near it.
//
//  **Only the places the line passes are kept.** A search puts everything it
//  found near the drawing onto it, which is the right amount while the route
//  is still being decided and far too much on a finished trail: the summit
//  across the valley is not a place on this walk. So a save keeps the places
//  within ``TrailPlaceAnchor/touchedOffRouteMeters`` of the route and drops
//  the rest — from the hike, not from the draft, which a refused save leaves
//  exactly as it was.
//
//  **And none of them while the switch beside *Search This Area* is off.**
//  That switch hides the drawing's places rather than removing them — see
//  ``TrailPlaceFilter/placesShown`` — so the save is where it takes effect: a
//  new trail is saved with no places, and an edit leaves the hike's own places
//  exactly as they were, since the maker had them out of sight and a save that
//  dropped them would be deleting what the hiker could not see.
//
//  **A leg still routing is saved as it stands.** Save does not wait: a hiker
//  who has finished drawing has finished, and holding the button while a
//  volunteer-run API is thinking about the last leg would make Overpass's
//  weather into this app's responsiveness. What they get is the straight
//  line that leg is currently drawn as, which is what they are looking at.
//
//  The commit happens here, before anything is told there is a hike, for the
//  reason ``HikeImport`` commits before its caller navigates: an insert is a
//  change pending in a context, and everything downstream of a successful save
//  — selecting the hike, drawing it, clearing the draft that made it — acts on
//  the claim that it is *kept*.
//
//  Unlike an import's, this commit stays on the main actor, in the context
//  the screen hands it — and not because the line is small. A snapped trail
//  is saved as the paths it follows, thousands of points rather than the
//  stops that were tapped, and a save flattens them, puts whatever heights
//  were read on every one, measures the places against them and serializes
//  them, all before the hike's screen can open. It stays for what it reads
//  and what it hands back: the stops, the legs and the places are the
//  draft's, which is main-actor state, and the hike that comes back is the
//  screen's own row, selected and drawn at once — an edit writes into the
//  very row the hike's screen holds. A save has not been timed on a long
//  snapped trail. If a timing ever finds it holding the button, the import's
//  shape is the one to take: the draft copied out as values, a context of
//  its own, and the row fetched back by id.
//

import Algorithms
import Foundation
import OpenHikesData
import os
import SwiftData

/// What one Save did.
///
/// An enumeration rather than an optional `Hike`, because the two refusals are
/// different sentences — one is about the line and one is about the disk —
/// and only one of them means the draft is worth keeping.
enum TrailDraftSaveOutcome {
    case refused(TrailDraftRefusal)
    case saved(Hike)

    var hike: Hike? {
        guard case .saved(let hike) = self else { return nil }
        return hike
    }
}

/// Why a drawn trail did not become a hike.
enum TrailDraftRefusal: LocalizedError, Equatable, Sendable {
    /// The store refused to keep it.
    ///
    /// Carries no diagnostic, for the reason ``HikeImportFailure/notSaved``
    /// carries none: what SwiftData says about a refused commit is not a
    /// sentence anybody can act on, so it is logged where it is useful and the
    /// alert says the part that is the hiker's to know.
    case notSaved
    /// Fewer than two points: a place rather than a trail.
    case tooShort

    var errorDescription: String? {
        switch self {
        case .tooShort: String(localized: "This trail needs at least two points.")
        case .notSaved: String(localized: "This trail couldn’t be saved.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        // Says the drawing is still there, because the obvious reading of a
        // failed save is that it is gone.
        case .tooShort:
            String(localized: "Tap the map to add another point, then save again.")
        case .notSaved:
            String(localized: "Your drawing wasn’t lost. Check that the device has storage available, then save again.")
        }
    }
}

enum TrailDraftSave {
    nonisolated private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "TrailDraft"
    )

    /// Persists `draft` as a hike under `name`, or says why it could not.
    ///
    /// The name arrives as an argument rather than off the draft, because it
    /// is typed into the alert that asks for it on the way out — see
    /// ``TrailDraftView``. A blank one is not a missing answer but the
    /// answer the placeholder promised: ``HikeTitle/drawn(name:madeOn:)``
    /// names the trail after the day it was drawn.
    ///
    /// - Parameter heights: what the line was measured at, or `nil` for a
    ///   drawing nothing has measured — a free hiker's, a build with no key,
    ///   or one saved before the answer landed. They are applied only if they
    ///   are still about *this* line; see ``RouteHeightSamples/describes(_:)``,
    ///   which is what keeps a leg that snapped while the alert was open from
    ///   putting a summit's height on a point in a valley.
    /// - Parameter keepingPlaces: the switch beside *Search This Area*; off
    ///   saves the trail with none of the drawing's places.
    /// - Parameter save: The seam the commit goes through, so a suite can
    ///   refuse it — the same shape ``HikeImport`` and
    ///   ``HikePhotoImport/remove(_:from:store:save:)`` take theirs in. There
    ///   is no sequence of taps that makes a store say no, and this is the one
    ///   failure whose whole point is what it does *not* leave behind.
    @discardableResult static func hike(
        from draft: TrailDraft,
        named name: String,
        into context: ModelContext,
        madeOn date: Date = .now,
        heights: RouteHeightSamples? = nil,
        keepingPlaces: Bool = true,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> TrailDraftSaveOutcome {
        let waypoints = draft.waypoints
        guard waypoints.count > 1 else { return .refused(.tooShort) }

        // Flattened once and used twice, because it is the expensive half of
        // this function: a snapped trail is thousands of coordinates and
        // ``TrailDraft/routeCoordinates`` builds the array afresh on every
        // read.
        let route = draft.routeCoordinates
        let hike = Hike(
            // Bounded here, where the name leaves the maker: this is the point
            // at which a typed string starts reaching payloads with ceilings
            // — see ``HikeTitle``, which owns the rule and both its bounds.
            title: HikeTitle.drawn(name: name, madeOn: date),
            distanceMeters: draft.distanceMeters,
            date: date,
            tintHex: Hike.randomTintHex(),
            // The resolved legs, not the points: a snapped trail is saved as
            // the paths it follows, which is the whole of what Phase 2 added
            // and the only thing about it that reaches the library, the
            // widget, GPX export and *Follow This Trail*. A freehand or
            // degraded leg contributes its two ends and is indistinguishable
            // from what Phase 1 wrote — see ``TrailDraft/routeCoordinates``.
            //
            // With whatever heights were read for it, on every point: read at
            // two hundred and interpolated between them, the heights the maker
            // coloured the line from while it was drawn — see
            // ``RouteHeightSamples/interpolating(_:)``. A degraded leg keeps
            // its heights too: the maker left it uncoloured so its dashes
            // showed, and a saved line draws no dashes. That is the whole of
            // what makes a drawn trail open with a profile, a climb, a descent
            // and its colours by steepness: nothing downstream of here knows
            // where a height came from, so the detail screen, the stat grid,
            // the map, GPX export and a published listing all draw them
            // without a line added to any of them.
            route: heights?.interpolating(route) ?? route
        )
        // The stops it was drawn from, so *Edit Route* can reopen it — see
        // ``DrawnRoute``.
        hike.drawnRoute = DrawnRoute(draft)
        context.insert(hike)
        // After the insert, because a ``TrailPoint`` is a row of its own and a
        // relationship assigned to a hike that is not in a context yet has
        // nowhere to put it. Before the commit, because the whole point of
        // committing here is that everything downstream acts on the claim that
        // what was drawn is *kept* — and a place written a moment later would
        // be a second chance to fail after the hiker has been told it worked.
        //
        // Measured against the route being saved rather than the draft's
        // ranked rows, which land a moment after an edit and may be about the
        // line before it. A leg Overpass refused, or one still routing, is
        // measured as the straight line it is saved as — nothing here waits on
        // anything, which is the rule the whole feature is built on.
        if keepingPlaces {
            hike.replacePlaces(
                with: TrailPlaceOrder.touched(draft.places, along: route),
                in: context,
                now: date
            )
        }
        do {
            try save(context)
        } catch {
            // The row goes with the refusal. A pending insert left behind for
            // the *next* save to accept would put the hike on the list a
            // moment after the hiker was told it wasn't there.
            context.delete(hike)
            logger.error(
                """
                A drawn trail could not be saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .refused(.notSaved)
        }
        return .saved(hike)
    }

    /// Writes `draft` back into `hike` — *Edit Route*'s Save.
    ///
    /// The same row, so every walk, place, photograph, widget pin and
    /// publication pointing at it still does. The name, the colour, the
    /// symbol and the date stay what they were; what changes is what the
    /// line is: the route and its length, the stops it was drawn from, and
    /// the places it passes — by the rule a new trail's save keeps them by. A
    /// place the edit took away returns its photographs to the gallery, as
    /// removing it on its own screen does.
    ///
    /// **Past walks are kept**, the owner's decision: a ``HikeWalk`` is a
    /// record of a walk that happened, measured against the route as it stood
    /// then. The surface and difficulty breakdowns are not kept — they
    /// describe the old line — and are emptied so the next open asks
    /// OpenStreetMap about the new one, which is what "never analyzed" means.
    ///
    /// A shared hike keeps its publication and learns that the shared copy
    /// is now out of date — see ``DrawnRoute/editedUnderSubmissionID``.
    ///
    /// - Parameter placesAtOpen: the hike's places when the edit opened — see
    ///   ``places(of:drawn:atOpen:)``, which is what it tells apart.
    /// - Parameter keepingPlaces: the switch beside *Search This Area*; off
    ///   leaves the hike's places as they are — see the file header.
    ///
    /// A refused save puts everything back: the rows through the context's
    /// rollback, and then by hand whatever of the hike's own columns and its
    /// list of place rows the rollback left as the edit wrote them, and
    /// nothing else — see ``UneditedHike/putBack(into:)``. Which that is
    /// depends on the OS. Measured on iOS 27.0, the rollback takes all of it
    /// back itself; measured on 18.6, the iOS 18 floor takes back none of it
    /// — see ``StoredTileDeletion`` for the columns and
    /// ``restorePlaceRows(of:to:)`` for the list. iOS 26 was not measured,
    /// and need not be: comparing before writing is right whichever way an
    /// OS goes. The rollback has nothing else to take, because what the
    /// context already held is committed first — see
    /// ``HikeDeletion/delete(_:store:workouts:save:)``, which does the same
    /// for the same reason.
    @discardableResult static func update(
        _ hike: Hike,
        from draft: TrailDraft,
        openedWith placesAtOpen: Set<UUID>,
        into context: ModelContext,
        heights: RouteHeightSamples? = nil,
        keepingPlaces: Bool = true,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> TrailDraftSaveOutcome {
        guard draft.waypoints.count > 1 else { return .refused(.tooShort) }
        // What the context already holds goes first, in a commit of its own,
        // before anything is touched: this is the shared main context, and a
        // rename waiting there for its autosave, or a drawing whose own commit
        // the store refused, is not this edit's to roll back. A store that
        // refuses this commit has refused the edit too.
        do {
            if context.hasChanges { try save(context) }
        } catch {
            return refusedEdit(error)
        }
        let route = draft.routeCoordinates
        // The hike's walks are read before anything is written, though the
        // edit never touches them. Measured on iOS 27.0: when the rollback
        // below takes back a place row this edit inserted, beside the columns
        // it wrote, a list of the hike's rows that nothing had read yet is
        // left unreadable, and the next read of the walks trapped inside
        // SwiftData. The hike's photo section reads them on every pass, and
        // the delete confirmation counts them. A list read first came back
        // readable, which is why the places, read by ``UneditedHike``, always
        // did.
        _ = hike.walks
        let before = UneditedHike(hike)
        let kept = keepingPlaces
            ? TrailPlaceOrder.touched(places(of: hike, drawn: draft.places, atOpen: placesAtOpen), along: route)
            : nil
        if let kept {
            let keptIDs = Set(kept.map(\.id))
            for place in hike.places where !keptIDs.contains(place.id) {
                hike.unfilePhotos(fromPlace: place.id)
            }
        }
        // Before the line changes: a download recorded without its box has
        // only the route to be recomputed from, and after this it would be
        // recomputed from the new one — tiles nobody fetched.
        hike.pinUnboxedDownloads()
        hike.replaceRoute(with: heights?.interpolating(route) ?? route)
        hike.distanceMeters = draft.distanceMeters
        hike.surfaceMetersByCategory = [:]
        hike.difficultyMetersByGrade = [:]
        // Clear figures about the old line immediately. The library also
        // validates their route identity, including edits received from
        // another device; see ``HikeListMetrics``.
        if before.climb != nil || before.descent != nil {
            hike.climbMeters = nil
            hike.descentMeters = nil
        }
        if before.elevationRevision != nil { hike.elevationRouteRevision = nil }
        hike.drawnRoute = DrawnRoute(draft, editedUnderSubmissionID: hike.communitySubmissionID)
        if let kept { hike.replacePlaces(with: kept, in: context) }
        do {
            try save(context)
        } catch {
            context.rollback()
            before.putBack(into: hike)
            return refusedEdit(error)
        }
        return .saved(hike)
    }

    /// The hike as an edit found it: every column
    /// ``update(_:from:openedWith:into:heights:keepingPlaces:save:)`` writes,
    /// and its list of place rows — all but the boxes
    /// ``Hike/pinUnboxedDownloads()`` pins, which are safe to leave after a
    /// refusal.
    private struct UneditedHike {
        let route: [RouteCoordinate]
        let distance: Double
        let drawn: Data?
        let surface: [String: Double]
        let difficulty: [String: Double]
        let photos: [HikePhoto]
        let points: [TrailPoint]
        let climb: Double?
        let descent: Double?
        let elevationRevision: String?

        init(_ hike: Hike) {
            route = hike.route
            distance = hike.distanceMeters
            drawn = hike.drawnRouteData
            surface = hike.surfaceMetersByCategory
            difficulty = hike.difficultyMetersByGrade
            photos = hike.photos
            points = hike.trailPoints ?? []
            climb = hike.climbMeters
            descent = hike.descentMeters
            elevationRevision = hike.elevationRouteRevision
        }

        /// Writes back what a refused edit's rollback left as the edit wrote
        /// it, and nothing the rollback took back.
        ///
        /// A column the rollback took back — on iOS 27.0, every one — is not
        /// written again, because `@Model` filters no same-value write
        /// (AGENTS.md *Render isolation, in practice*). Written anyway, it
        /// left the hike changed in the shared context, and that context's
        /// next save — an autosave, a rename — put the pre-edit breakdown and
        /// length over the ones another context had saved since, as an import
        /// or the hiker's other device would: measured on iOS 27.0. A column
        /// the rollback left as the edit wrote it — on the iOS 18 floor,
        /// every one, with no change pending — is put back, or the next save
        /// that writes the hike for any reason would write the refused edit.
        /// That leaves the hike changed there, and on the floor a save writes
        /// a changed row whole, so the next one can still put the pre-edit
        /// values over another context's.
        func putBack(into hike: Hike) {
            if hike.route != route { hike.replaceRoute(with: route) }
            if hike.distanceMeters != distance { hike.distanceMeters = distance }
            if hike.drawnRouteData != drawn { hike.drawnRouteData = drawn }
            if hike.surfaceMetersByCategory != surface { hike.surfaceMetersByCategory = surface }
            if hike.difficultyMetersByGrade != difficulty { hike.difficultyMetersByGrade = difficulty }
            if hike.photos != photos { hike.photos = photos }
            TrailDraftSave.restorePlaceRows(of: hike, to: points)
            if hike.climbMeters != climb { hike.climbMeters = climb }
            if hike.descentMeters != descent { hike.descentMeters = descent }
            if hike.elevationRouteRevision != elevationRevision { hike.elevationRouteRevision = elevationRevision }
        }
    }

    /// Puts a refused edit's place rows back in the hike's list of them.
    ///
    /// The rows the edit deleted come back with the rollback, but on the iOS
    /// 18 floor the hike's own list of them does not: measured on 18.6, a
    /// restored row names the hike while the hike still lists none, and the
    /// columns put back by hand make the next save write that empty list,
    /// leaving the place on disk with no hike. On iOS 27 the list is back
    /// already, and this compares equal.
    private static func restorePlaceRows(of hike: Hike, to points: [TrailPoint]) {
        guard hike.trailPoints?.map(\.persistentModelID) != points.map(\.persistentModelID) else { return }
        hike.trailPoints = points
    }

    private static func refusedEdit(_ error: any Error) -> TrailDraftSaveOutcome {
        logger.error(
            """
            An edited trail could not be saved: \
            \(error.localizedDescription, privacy: .public)
            """
        )
        return .refused(.notSaved)
    }

    /// The places an edit's save chooses from: the drawing's, merged with what
    /// happened to the hike's own while the edit was open.
    ///
    /// An edit can stay open for days — the back button keeps it, and so does
    /// a relaunch — while the hike's screen goes on taking places: *Add
    /// Place*, *Places Around Trail*, a rename, a note, a removal, or any
    /// of those arriving from the hiker's other device. The drawing holds a
    /// copy taken when it opened, so saving that copy as it stood would delete
    /// what was added since, photographs unfiled, and put back what was
    /// removed or renamed. `atOpen` is what tells the two apart:
    ///
    /// - one the drawing and the hike both hold is the **hike's** — the maker
    ///   can take a place away but never changes one, so the hike's copy is
    ///   the newer;
    /// - one only the drawing holds is new from the maker's search, unless
    ///   the hike held it at the open, in which case it was removed since;
    /// - one only the hike holds was added since, unless the hike held it at
    ///   the open, in which case the maker removed it.
    ///
    /// Everything that survives still has to pass the line, like any save.
    static func places(of hike: Hike, drawn: [TrailPlace], atOpen: Set<UUID>) -> [TrailPlace] {
        let held = hike.places
        let heldByID = held.keyed(by: \.id, resolvingConflictsWith: { _, first, _ in first })
        let drawnIDs = Set(drawn.map(\.id))
        let fromDrawing = drawn.compactMap { place in
            heldByID[place.id] ?? (atOpen.contains(place.id) ? nil : place)
        }
        let addedSince = held.filter { !drawnIDs.contains($0.id) && !atOpen.contains($0.id) }
        return fromDrawing + addedSince
    }
}
