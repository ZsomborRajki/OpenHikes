//
//  DrawnRoute.swift
//  OpenHikes
//
//  What a drawn trail was drawn *from*, kept on the hike so it can be drawn
//  again.
//
//  A save used to throw the stops away: ``TrailDraftSave`` wrote the resolved
//  line as an ordinary ``Hike`` and nothing else, so moving one stop on a
//  trail drawn yesterday meant drawing the whole thing again. Planning is
//  iterative — draw it, check the weather, move the turnaround — and every
//  route planner a hiker compares this with reopens a plan.
//
//  ## On the hike, and synced
//
//  Not in ``HikeLocalState``: a route should be editable on the hiker's other
//  device as well, and the stops are a fact about the trail rather than about
//  this phone's files. One `Data` column holding this value as JSON rather
//  than a column per field, so the whole plan crosses CloudKit as one
//  `CD_drawnRouteData` field and a later addition to it costs no schema
//  change. `nil` for every hike that was not drawn in the maker — a recording
//  or an import has no stops to reopen, and re-routing a line somebody
//  actually walked would replace it with a guess (the owner's decision: Edit
//  Route is for maker-born hikes only).
//
//  ## A published trail that was edited
//
//  A submission is write-once, and *Share Again* is gone for the reason the
//  community section gives — so editing a published trail changes the hike
//  and not the listing. ``editedUnderSubmissionID`` remembers which submission
//  the hike had when its route was last edited, and the share menu says the
//  shared copy shows the old route while that is still the submission. A
//  fresh share after a removal is a new submission, and the note goes on its
//  own.
//

import Foundation

nonisolated struct DrawnRoute: Codable, Equatable, Sendable {
    /// The stops, in order, with the names they carried.
    var waypoints: [RouteCoordinate]
    var waypointNames: [String]
    var travelMode: TrailTravelMode
    var snapsToPaths: Bool
    /// The hike's ``Hike/communitySubmissionID`` when this route was last
    /// edited, or `nil` for a route never edited while shared.
    var editedUnderSubmissionID: String?

    /// The stops as the maker works in them. Names are paired only when there
    /// is one per point, the rule ``TrailDraftStore`` applies for the same
    /// reason.
    var trailWaypoints: [TrailWaypoint] {
        let names = waypointNames.count == waypoints.count ? waypointNames : []
        return waypoints.enumerated().map { index, point in
            TrailWaypoint(
                latitude: point.latitude,
                longitude: point.longitude,
                name: names.indices.contains(index) ? names[index] : ""
            )
        }
    }
}

extension DrawnRoute {
    /// What `draft` was drawn from.
    @MainActor
    init(_ draft: TrailDraft, editedUnderSubmissionID: String? = nil) {
        waypoints = draft.waypoints.map(\.routeCoordinate)
        waypointNames = draft.waypoints.map(\.name)
        travelMode = draft.travelMode
        snapsToPaths = draft.snapsToPaths
        self.editedUnderSubmissionID = editedUnderSubmissionID
    }
}

extension Hike {
    /// What this trail was drawn from, or `nil` for one that was not drawn in
    /// the maker — see ``DrawnRoute``. A value that fails to decode reads as
    /// `nil`, which withdraws Edit Route rather than opening a broken plan.
    var drawnRoute: DrawnRoute? {
        get {
            guard let drawnRouteData else { return nil }
            return try? JSONDecoder().decode(DrawnRoute.self, from: drawnRouteData)
        }
        set {
            drawnRouteData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Whether the shared copy of this trail shows a route it has since been
    /// edited away from — see ``DrawnRoute/editedUnderSubmissionID``.
    var isSharedCopyOutOfDate: Bool {
        guard let submission = communitySubmissionID else { return false }
        return drawnRoute?.editedUnderSubmissionID == submission
    }
}
