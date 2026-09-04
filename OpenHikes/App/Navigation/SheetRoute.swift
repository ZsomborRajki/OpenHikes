//
//  SheetRoute.swift
//  OpenHikes
//

import Foundation
import SwiftData

enum SheetRoute: Hashable {
    case hike(Hike)
    /// A hike's gallery, opened at one photo. Carries the hike rather than the
    /// photo so the viewer can page through the rest of them, and so a photo
    /// deleted from inside the viewer doesn't invalidate the route showing it.
    case photo(Hike, UUID)
    case recording
    /// A finished walk's summary. Carries the walk, whose `hikeID` says which
    /// hike's screens it belongs under — so deleting the hike pops its
    /// summaries with it.
    case walk(HikeWalk)

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
        case let .walk(walk): walk.hikeID == hikeID
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

    // Spelled out rather than synthesized, because the compiler cannot see
    // `HikeWalk`'s `PersistentModel` conformance from here: `Hike` names
    // `\HikeWalk.hike` in its relationship and `HikeWalk` names `Hike`, and
    // the two macro expansions refer to each other. The identities compared
    // are the ones the synthesis would have used.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.hike(left), .hike(right)): left == right
        case let (.photo(left, leftPhoto), .photo(right, rightPhoto)): left == right && leftPhoto == rightPhoto
        case (.recording, .recording): true
        case let (.walk(left), .walk(right)): left.persistentModelID == right.persistentModelID
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .hike(hike):
            hasher.combine(0)
            hasher.combine(hike)
        case let .photo(hike, photoID):
            hasher.combine(1)
            hasher.combine(hike)
            hasher.combine(photoID)
        case .recording:
            hasher.combine(2)
        case let .walk(walk):
            hasher.combine(3)
            hasher.combine(walk.persistentModelID)
        }
    }
}
