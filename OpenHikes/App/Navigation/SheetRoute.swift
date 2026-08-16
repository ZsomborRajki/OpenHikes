//
//  SheetRoute.swift
//  OpenHikes
//

import Foundation

enum SheetRoute: Hashable {
    case hike(Hike)
    /// A hike's gallery, opened at one photo. Carries the hike rather than the
    /// photo so the viewer can page through the rest of them, and so a photo
    /// deleted from inside the viewer doesn't invalidate the route showing it.
    case photo(Hike, UUID)
    case recording

    static func reopenRecording(in path: inout [Self]) {
        path = [.recording]
    }

    static func openRecording(
        hike: Hike?,
        selectedHike: inout Hike?,
        in path: inout [Self]
    ) {
        if let hike {
            selectedHike = hike
        }
        reopenRecording(in: &path)
    }

    /// Whether this route is showing the given hike — a pushed photo viewer
    /// counts, since deleting a hike takes its gallery with it.
    func shows(hikeID: UUID) -> Bool {
        switch self {
        case let .hike(hike): hike.id == hikeID
        case let .photo(hike, _): hike.id == hikeID
        case .recording: false
        }
    }

    /// Whether this route wants the whole sheet. The photo viewer does: it
    /// draws one picture and nothing else, and a picture in the medium detent
    /// is a stamp.
    var prefersFullHeight: Bool {
        if case .photo = self { true } else { false }
    }
}
