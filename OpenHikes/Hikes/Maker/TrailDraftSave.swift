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
//  The consequence, stated rather than discovered: a drawn trail is
//  indistinguishable from an imported one, and its `date` is the day it was
//  made rather than a day it was walked. That is consistent — an imported
//  trail is also a line somebody drew elsewhere — and there is deliberately no
//  *planned* flag and no exclusion from the library's totals. Adding one later
//  is a column, not a redesign.
//
//  Two points is the floor, and it is a refusal rather than a disabled button
//  alone: one point is a place, and a `Hike` whose route is a single
//  coordinate has no length, no profile and nothing to draw. **The places
//  marked along it do not count towards that floor and cannot rescue a draft
//  below it**, which is the same distinction everywhere else in this feature:
//  a place is a spot on the ground beside a trail, not part of one, and a
//  saved hike with no route is not a hike whatever is marked near it.
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
//  the claim that it is *kept*. Unlike an import this stays on the main actor:
//  a drawn trail is a few dozen points, not the twenty thousand a day's
//  recording serializes.
//

import Foundation
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
        case .notSaved: String(localized: "This trail couldn't be saved.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        // Says the drawing is still there, because the obvious reading of a
        // failed save is that it is gone.
        case .tooShort:
            String(localized: "Tap the map to add another point, then save again.")
        case .notSaved:
            String(localized: "Your drawing wasn't lost. Check that the device has storage available, then save again.")
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
            // With whatever heights were read for it, on the two hundred
            // points they were read at. That is the whole of what makes a
            // drawn trail open with a profile, a climb and a descent: nothing
            // downstream of here knows where a height came from, so the
            // detail screen, the stat grid, GPX export and a published
            // listing all draw them without a line added to any of them.
            route: heights?.filling(route) ?? route
        )
        context.insert(hike)
        // After the insert, because a ``TrailPoint`` is a row of its own and a
        // relationship assigned to a hike that is not in a context yet has
        // nowhere to put it. Before the commit, because the whole point of
        // committing here is that everything downstream acts on the claim that
        // what was drawn is *kept* — and a place written a moment later would
        // be a second chance to fail after the hiker has been told it worked.
        //
        // The places are saved whatever the line did. A place marked beside a
        // leg Overpass refused is still a place; nothing here waits on
        // anything, which is the rule the whole feature is built on.
        hike.replacePlaces(with: draft.places, in: context, now: date)
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
}
