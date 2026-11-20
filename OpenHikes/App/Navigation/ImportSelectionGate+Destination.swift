//
//  ImportSelectionGate+Destination.swift
//  OpenHikes
//
//  Which screen a navigation path is showing, as far as an import finishing
//  under it is concerned — see ``ImportSelectionGate``. Split from the gate
//  for length, and into three switches so each stays inside the complexity
//  limit.
//

import Foundation
import OpenHikesData

extension ImportSelectionGate {
    func destination(for path: [SheetRoute]) -> Destination {
        guard let route = path.last else { return .root }
        if let hikeID = Self.hikeScreen(route) { return .hike(hikeID) }
        if let screen = Self.bareScreen(route) { return screen }
        switch route {
        case .communityHike(let listing): return .communityHike(listing.id)
        // A shared hike's gallery is that preview's screen one push further
        // in, on the same terms the photo viewer is the hike's.
        case .communityPhoto(let listing, _, _): return .communityHike(listing.id)
        case .pendingSubmission(let pending): return .pendingSubmission(pending.id)
        // A contributed set under review is the same kind of screen and gets
        // the same protection, keyed on its own queue entry.
        case .pendingPhotos(let pending): return .pendingSubmission(pending.id)
        // The gallery over a photograph is its screen one push further in, on
        // the terms a shared hike's is its preview's.
        case .commonsPhoto(let photo), .commonsGallery(_, let photo):
            return .commonsPhoto(photo.credit.license.sourceURL)
        case .commonsPhotos(let photos): return .commonsPhotos(photos.map(\.credit.license.sourceURL))
        // Answered by the two above.
        case .hike, .newPlace, .offlineCountries, .photo, .place, .placesAround, .placesNearby, .recording,
            .routeEdit, .routeStyle, .totals, .trailDraft, .walk:
            return .root
        }
    }

    /// The screen `route` is when it carries nothing to tell two of it apart,
    /// or `nil` for any other.
    private static func bareScreen(_ route: SheetRoute) -> Destination? {
        switch route {
        // *Places Nearby* is the recording's screen one push further in, and
        // an import landing under it must not take the map from the walk.
        case .recording, .placesNearby: .recording
        case .trailDraft: .trailDraft
        case .totals: .totals
        case .offlineCountries: .offlineCountries
        case .commonsGallery, .commonsPhoto, .commonsPhotos, .communityHike, .communityPhoto, .hike, .newPlace,
            .pendingPhotos, .pendingSubmission, .photo, .place, .placesAround, .routeEdit, .routeStyle, .walk:
            nil
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
        case .placesAround(let hike): hike.id
        case .routeEdit(let hike), .routeStyle(let hike): hike.id
        case .walk(let walk): walk.hikeID
        case .commonsGallery, .commonsPhoto, .commonsPhotos, .communityHike, .communityPhoto, .pendingPhotos,
            .offlineCountries, .pendingSubmission, .placesNearby, .recording, .totals, .trailDraft:
            nil
        }
    }
}
