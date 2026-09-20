//
//  ReObservation.swift
//  OpenHikes
//
//  Watching an `@Observable` from outside SwiftUI, for as long as the watcher
//  lives.
//
//  `withObservationTracking` fires once and then forgets, so every continuous
//  observation in this app is really a loop: apply what changed, then register
//  again. That loop is the technique the map's whole render-isolation story
//  rests on — a colour well, a sheet drag and a GPS fix all reach MapKit
//  without travelling through a SwiftUI body — and it was written out by hand
//  in a dozen places, identically and for good reason, because the ceremony
//  around it is not obvious:
//
//  **The re-registration is the load-bearing line.** An `onChange` that fails
//  to register again is silently forgotten: nothing errors, nothing logs, and
//  the map simply stops following whatever it was following. It is the one
//  mistake this shape invites and the one nothing downstream would report.
//
//  **The captures have to be weak, and then read once.** The handler outlives
//  the objects it watches — a coordinator goes when its map view does, a
//  browser when the sheet closes — so every reference is `weak`, and each is
//  read into a local before the hop rather than unwrapped inside it, so the
//  optional crosses once rather than the mutable capture. The hop itself is
//  not optional: `onChange` is `@Sendable` and arrives wherever the write
//  happened, while everything it touches here is main-actor state.
//
//  **`Sendable` is what makes the generic version legal**, and it costs the
//  call sites nothing: every watcher and every subject below is a main-actor
//  isolated class, and global-actor isolation supplies the conformance. A
//  type that is genuinely free to move between threads has no business on
//  this path anyway — what is on the other side of the hop is a map view.
//
//  So the ceremony lives here once and the call sites say what they watch and
//  what to do about it. What they must still do themselves is **apply before
//  registering** — the first pass has to run for the state that is already
//  there, which is why every caller below calls its own `apply…` and then this
//  — and **call itself back** from `onChange`, which is what keeps the loop
//  going.
//

import Observation

/// Watches `keys` on behalf of two objects, then hands both back on the main
/// actor when something changes.
///
/// Neither object is kept alive: if either is gone by the time a change
/// arrives, the change is dropped and the loop ends with it, which is the
/// correct end for an observation whose watcher or subject has been torn down.
@MainActor
func reobserving<Owner: AnyObject & Sendable, Subject: AnyObject & Sendable>(
    _ owner: Owner,
    _ subject: Subject,
    tracking keys: () -> Void,
    onChange body: @escaping @MainActor @Sendable (Owner, Subject) -> Void
) {
    withObservationTracking(keys) { [weak owner, weak subject] in
        let heldOwner = owner
        let heldSubject = subject
        Task { @MainActor in
            guard let heldOwner, let heldSubject else { return }
            body(heldOwner, heldSubject)
        }
    }
}

/// The same, for the map's observations: a coordinator, the map view it draws
/// into, and the model it is watching.
///
/// A third parameter rather than a tuple, because all three are separately
/// weak — a map view can go while its model lives on, and a model can go while
/// the map view is still on screen.
@MainActor
func reobserving<Owner: AnyObject & Sendable, View: AnyObject & Sendable, Subject: AnyObject & Sendable>(
    _ owner: Owner,
    _ view: View,
    _ subject: Subject,
    tracking keys: () -> Void,
    onChange body: @escaping @MainActor @Sendable (Owner, View, Subject) -> Void
) {
    withObservationTracking(keys) { [weak owner, weak view, weak subject] in
        let heldOwner = owner
        let heldView = view
        let heldSubject = subject
        Task { @MainActor in
            guard let heldOwner, let heldView, let heldSubject else { return }
            body(heldOwner, heldView, heldSubject)
        }
    }
}

/// The one-object case: something watching its own state rather than another
/// object's.
///
/// Still a hop and still weak, for the reasons above — what it does not need
/// is a second reference to check.
@MainActor
func reobserving<Owner: AnyObject & Sendable>(
    _ owner: Owner,
    tracking keys: () -> Void,
    onChange body: @escaping @MainActor @Sendable (Owner) -> Void
) {
    withObservationTracking(keys) { [weak owner] in
        let heldOwner = owner
        Task { @MainActor in
            guard let heldOwner else { return }
            body(heldOwner)
        }
    }
}
