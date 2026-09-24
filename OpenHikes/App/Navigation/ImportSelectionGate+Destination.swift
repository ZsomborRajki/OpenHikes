//
//  ImportSelectionGate+Destination.swift
//  OpenHikes
//
//  Which screen a navigation path is showing, as far as an import finishing
//  under it is concerned — see ``ImportSelectionGate``. Split from the gate
//  for length, and into two switches so neither is a list of every route.
//

import Foundation

extension ImportSelectionGate {
    func destination(for path: [SheetRoute]) -> Destination {
        guard let route = path.last else { return .root }
        if let hikeID = Self.hikeScreen(route) { return .hike(hikeID) }
        switch route {
        case .recording: return .recording
        case .trailDraft: return .trailDraft
        case .totals: return .totals
        case .communityHike(let listing): return .communityHike(listing.id)
        // A shared hike's gallery is that preview's screen one push further
        // in, on the same terms the photo viewer is the hike's.
        case .communityPhoto(let listing, _, _): return .communityHike(listing.id)
        case .pendingSubmission(let pending): return .pendingSubmission(pending.id)
        // A contributed set under review is the same kind of screen and gets
        // the same protection, keyed on its own queue entry.
        case .pendingPhotos(let pending): return .pendingSubmission(pending.id)
        case .hike, .newPlace, .photo, .place, .walk: return .root
        }
    }

    /// The hike whose screen `route` is — the hike's own, or one of the
    /// screens a push or two further in, where an import arriving is still
    /// landing on the hike the hiker is looking at — or `nil` for any other.
    private static func hikeScreen(_ route: SheetRoute) -> UUID? {
        switch route {
        case .hike(let hike): hike.id
        case .photo(let hike, _): hike.id
        case .place(let hike, _): hike.id
        case .newPlace(let hike, _): hike.id
        case .walk(let walk): walk.hikeID
        case .communityHike, .communityPhoto, .pendingPhotos, .pendingSubmission, .recording, .totals,
            .trailDraft:
            nil
        }
    }
}
