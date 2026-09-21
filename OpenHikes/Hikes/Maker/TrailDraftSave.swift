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
//  coordinate has no length, no profile and nothing to draw.
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

    /// Persists `draft` as a hike, or says why it could not.
    ///
    /// - Parameter save: The seam the commit goes through, so a suite can
    ///   refuse it — the same shape ``HikeImport`` and
    ///   ``HikePhotoImport/remove(_:from:store:save:)`` take theirs in. There
    ///   is no sequence of taps that makes a store say no, and this is the one
    ///   failure whose whole point is what it does *not* leave behind.
    @discardableResult static func hike(
        from draft: TrailDraft,
        into context: ModelContext,
        madeOn date: Date = .now,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> TrailDraftSaveOutcome {
        let waypoints = draft.waypoints
        guard waypoints.count > 1 else { return .refused(.tooShort) }

        let hike = Hike(
            // Bounded here, where the name leaves the maker: this is the point
            // at which a typed string starts reaching payloads with ceilings
            // — see ``HikeTitle``, which owns the rule and both its bounds.
            title: HikeTitle.drawn(name: draft.name, madeOn: date),
            distanceMeters: draft.distanceMeters,
            date: date,
            tintHex: Hike.randomTintHex(),
            route: waypoints.map(\.routeCoordinate)
        )
        context.insert(hike)
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
