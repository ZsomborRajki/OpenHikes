//
//  TrailDraftHistory.swift
//  OpenHikes
//
//  What the drawing looked like before the last few things the hiker did.
//
//  Phase 1 shipped with one way out of a mis-tap, and it was Cancel: throw the
//  whole trail away and start again. That was survivable while a tap was the
//  only thing a hiker could do. Phase 3 adds five more — drag, insert, delete,
//  reorder, reverse — and every one of them is a gesture that can land
//  somewhere it was not aimed. Undo is what makes those safe to try.
//
//  ## Whole lists, not operations
//
//  A step here is the waypoint list as it stood, not *what was done to it*. An
//  inverse-operation history has to know how to undo each of the six, has to
//  gain a case for each one added later, and gets a reorder or a reverse wrong
//  in a way nobody notices until a hiker undoes one. A list of points is a
//  handful of coordinates and two identifiers, so keeping the whole thing
//  costs nothing worth the arithmetic — see ``TrailDraft`` for the one thing
//  that *is* too big to snapshot, and which is remembered by
//  ``TrailLegMemo`` instead so that undo restores the resolved geometry rather
//  than re-fetching it.
//
//  **The drawing, and not the settings.** A step is the waypoints *and the
//  marked places* — see ``TrailDraftContents`` — because both are things a
//  hiker put on the map and both can be put there by mistake. Whether legs
//  follow mapped paths is not: it is a setting, written down with the points
//  precisely because it describes how they are being drawn, so an undo that
//  flipped it back would be undoing something the hiker did not do to the
//  line.
//
//  ## Redo is dropped by the next edit, and that is the standard rule
//
//  Undoing three steps and then drawing something new abandons the three:
//  they are no longer a future this drawing could have, because the branch
//  they belonged to has been left. Keeping them would offer a *Redo* that
//  replaces the line the hiker has just drawn with an unrelated one.
//

import Foundation

/// Everything one step of undo puts back.
///
/// The two lists together rather than a stack each, because they are edited
/// against each other: clearing a drawing takes both, and a hiker who marks a
/// spring, deletes two waypoints and then undoes twice expects the two undos
/// to walk back through what they actually did rather than through two
/// unrelated histories that happen to share a button.
nonisolated struct TrailDraftContents: Equatable, Sendable {
    var waypoints: [TrailWaypoint] = []
    var places: [TrailPlace] = []
    /// See ``TrailDraft/startIsOpen``. Part of a step because deleting a start
    /// and undoing it has to put the lone point back in the field it was in.
    var startIsOpen = false
}

/// The undo and redo stacks for one drawing.
///
/// A value type held by ``TrailDraft``, so every change to it publishes
/// through the draft's own observation and the two buttons that read
/// ``canUndo`` and ``canRedo`` update with the line.
nonisolated struct TrailDraftHistory: Equatable, Sendable {
    /// How many steps back a hiker can go.
    ///
    /// Deep enough that undo covers a stretch of drawing rather than the last
    /// thing done — which is the difference between a safety net and a
    /// twitch-correction — and shallow enough that a session spent
    /// rearranging a long trail does not keep every list it ever had.
    static let depth = 50

    private(set) var past: [TrailDraftContents] = []
    private(set) var future: [TrailDraftContents] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Remembers `contents` as the state to come back to, and abandons
    /// whatever was ahead.
    ///
    /// Called *before* the change it is about, with the drawing as it stands,
    /// so a caller that records and then does nothing has cost a step and
    /// changed nothing else.
    mutating func record(_ contents: TrailDraftContents) {
        past.append(contents)
        if past.count > Self.depth { past.removeFirst() }
        future = []
    }

    /// Puts `contents` back to the step before it, and hands the drawing it
    /// was holding to the redo stack.
    ///
    /// In place, and taking the current drawing rather than only handing one
    /// back: an undo stack on its own cannot answer what *redo* should
    /// restore, and the move has to be one operation or the two stacks can be
    /// left disagreeing about which drawing is in force.
    ///
    /// - Returns: whether there was a step to take.
    @discardableResult mutating func undo(_ contents: inout TrailDraftContents) -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(contents)
        contents = previous
        return true
    }

    @discardableResult mutating func redo(_ contents: inout TrailDraftContents) -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(contents)
        contents = next
        return true
    }

    /// Forgets everything. What starting a different drawing does — a restore
    /// from disk, or a draft cleared on the way out — because the steps behind
    /// a line belong to that line.
    mutating func forget() {
        past = []
        future = []
    }
}
