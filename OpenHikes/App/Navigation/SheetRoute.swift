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

    /// Takes a deleted hike out of the sheet's selection and navigation stack,
    /// reporting whether the selection was the one deleted.
    ///
    /// Extracted from `MapSheet.delete(_:among:)` so a test can call the rule
    /// rather than restate it. While it lived inside that private view method
    /// the only way to cover it was to re-implement it in the test, which pins
    /// the reasoning but cannot fail when the call site drifts away from it —
    /// and the call site is the half that has a deleted hike in front of it.
    ///
    /// The path is cleared unconditionally where the selection is not: a
    /// widget deep link pushes a trail directly, so "pushed" and "selected"
    /// are not guaranteed to be the same hike.
    ///
    /// - Returns: `true` when the deleted hike was the selected one, so the
    ///   caller knows to clear the map highlight with it.
    @discardableResult static func removeHike(
        _ hikeID: UUID,
        selectedHike: inout Hike?,
        from path: inout [Self]
    ) -> Bool {
        let wasSelected = selectedHike?.id == hikeID
        if wasSelected { selectedHike = nil }
        path.removeAll { $0.shows(hikeID: hikeID) }
        return wasSelected
    }

    /// Whether this route wants the whole sheet. The photo viewer does: it
    /// draws one picture and nothing else, and a picture in the medium detent
    /// is a stamp.
    var prefersFullHeight: Bool {
        if case .photo = self { true } else { false }
    }
}
