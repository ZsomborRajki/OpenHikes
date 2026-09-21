//
//  TrailDraftController.swift
//  OpenHikes
//
//  Whether the map is offering to make a trail, whether it is currently one
//  big drawing surface, and the one place a waypoint is put down.
//
//  A reference type for the reason ``PhotoCaptureController`` is one, and it
//  is the same geometry: the pill is on the map, the screen it opens is inside
//  the sheet's navigation stack, and the tap that adds a point arrives at
//  `MapView.Coordinator` — three places that cannot see each other. They all
//  attach here instead, and the map observes only what it draws.
//
//  ## The two pills can never both be up, and nothing enforces it
//
//  That is the point of putting the maker in the slot the camera pill already
//  occupies. ``PhotoCaptureController/refreshAvailability()`` is
//  `subject != nil && hasHostScreen`, so the camera is offered only while a
//  screen is pushed *and* that screen has attached a hike to photograph; this
//  one is offered only while **no** screen is pushed. The maker itself is a
//  pushed screen that attaches no photo subject, so opening it withdraws this
//  pill without offering the other. The exclusion falls out of the two
//  definitions rather than out of a rule either of them has to remember, which
//  is why neither of these types knows the other exists.
//
//  ## Every mutation goes through here
//
//  The map appends a waypoint and the maker's screen renames, cancels and
//  saves — and all of them land on ``TrailDraft`` through this object, because
//  this is the one that also knows the draft has to be written down. A screen
//  that mutated the draft directly would leave the durable copy behind by
//  exactly one tap, every time.
//

import CoreLocation
import Foundation
import Observation
import SwiftUI

@Observable
final class TrailDraftController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The line being drawn. Handed to the map, which observes it directly, so
    /// a tap that adds a point re-renders no SwiftUI view.
    let draft: TrailDraft

    /// Whether the map should be offering to make a trail. Observed directly
    /// by ``MapView/Coordinator``, so showing or hiding the pill never
    /// re-renders a view.
    private(set) var isAvailable = false

    /// Whether the map is the maker's canvas right now: a tap means *put a
    /// point here* and means nothing else.
    ///
    /// Observed by the coordinator, which is what suspends the drawn-route and
    /// shared-line hit tests while it holds — see `MapCoordinator+RouteTap.swift`.
    /// One tap, one meaning.
    private(set) var isEditing = false

    /// A one-shot request to open the maker, in the shape ``MapController``'s
    /// commands take: a token whose *change* is the message.
    private(set) var openRequest = 0

    /// Where the draft is kept between launches, or `nil` for a launch that
    /// remembers nothing — a preview, or a suite asking only about the pill.
    @ObservationIgnored private let store: TrailDraftStore?

    /// Whether the sheet has any screen pushed. The inverse of what the pill
    /// is offered on; see the note above on why that is the whole exclusion.
    ///
    /// Starts `true`, like ``PhotoCaptureController``'s, so the pill is
    /// withheld until the sheet has said otherwise rather than flashing in
    /// over a launch that restored a pushed screen.
    @ObservationIgnored private var hasPushedScreen = true

    init(store: TrailDraftStore? = nil) {
        self.store = store
        draft = TrailDraft()
    }

    /// Reports whether the sheet has a screen pushed, which is the whole of
    /// what decides the pill.
    ///
    /// Written by ``MapSheet`` as a function of its navigation path rather
    /// than as a push event, for the reason
    /// ``PhotoCaptureController/setHostScreenPresent(_:)`` is: a pop's
    /// `onDisappear` arrives only after the animation, which would leave this
    /// pill standing over the map and answering taps for the whole of a back
    /// navigation, and an abandoned back-swipe recomputes to the same answer
    /// rather than leaving it withdrawn for good.
    func setHostScreenPresent(_ present: Bool) {
        guard hasPushedScreen != present else { return }
        hasPushedScreen = present
        refreshAvailability()
    }

    /// Reports whether the maker's screen is the one on top.
    ///
    /// Written from the sheet's path for the reason above, and it has to be:
    /// a tap landing on the map during the pop animation would put down a
    /// waypoint on a trail the hiker has just left.
    ///
    /// Opening restores whatever was left half-drawn; closing writes down what
    /// is there, which is what carries a name typed but never followed by a
    /// tap.
    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if editing {
            restoreIfNeeded()
        } else {
            persist()
        }
    }

    /// Asks for the maker. Refused when the pill isn't available, so a tap
    /// that races the withdrawal above cannot push a screen from a map that
    /// has stopped offering one.
    func requestOpen() {
        guard isAvailable else { return }
        openRequest &+= 1
    }

    /// Puts a point down at the end of the line.
    ///
    /// Refused unless the maker is up, which is the same guard
    /// ``PhotoCaptureController/requestCamera()`` makes and for the same
    /// reason: the map's recognizer sees every tap, and the one that arrives
    /// as the screen is leaving must not be the one that changes the trail.
    func appendWaypoint(at coordinate: CLLocationCoordinate2D) {
        guard isEditing else { return }
        draft.append(coordinate)
        persist()
    }

    /// Drives the maker's name field, for the reason
    /// ``SheetPresentation/searchTextBinding`` drives the search field: the
    /// text is written by the keyboard, which no call site here would ever
    /// see.
    ///
    /// Deliberately **not** written down per keystroke. The name is carried to
    /// disk by the next waypoint, or by the maker closing — see
    /// ``setEditing(_:)`` — because a store write per character is a disk
    /// write per character for a value that nothing but this field reads until
    /// Save.
    var nameBinding: Binding<String> {
        Binding(get: { self.draft.name }, set: { self.draft.name = $0 })
    }

    /// Throws the drawing away: what Cancel does, and what a completed Save
    /// does with what it has just turned into a hike.
    func discard() {
        draft.clear()
        store?.clear()
    }

    private func restoreIfNeeded() {
        // Only into an empty draft. Leaving the maker and coming back within a
        // launch finds the line still in memory, and overwriting it with the
        // copy on disk would undo whatever was added after the last write.
        guard draft.isEmpty, let stored = store?.load() else { return }
        draft.replace(with: stored.waypoints, name: stored.name)
    }

    private func persist() {
        guard let store else { return }
        guard !draft.isEmpty || !draft.name.isEmpty else {
            store.clear()
            return
        }
        store.save(name: draft.name, waypoints: draft.waypoints)
    }

    private func refreshAvailability() {
        let available = !hasPushedScreen
        guard isAvailable != available else { return }
        isAvailable = available
    }
}
