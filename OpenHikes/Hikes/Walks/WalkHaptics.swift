//
//  WalkHaptics.swift
//  OpenHikes
//
//  What walking a trail feels like, in the recording's vocabulary.
//
//  A walk speaks the same moments as a recording — it began, it paused, it was
//  kept — and reads them off a different state machine, so it answers the
//  shared table in ``HapticMoment/walk(from:to:)`` through the projection
//  below rather than growing a second table of its own.
//
//  It stops short in one place, and that is the whole reason this file exists.
//  ``TrailWalkSession/phase`` goes to `nil` when a walk ends and says nothing
//  about *how*: under a hundred metres it is dropped, over it is kept, and a
//  store that refuses leaves the walk running. Only ``TrailWalkEnd`` knows,
//  and it is returned to the button that asked. So the phase reports the
//  beginning and the middle, ``moment(for:)`` reports the end, and neither
//  reports the other — which is what keeps a kept walk from being announced
//  twice, once correctly and once as a discard.
//

import OpenHikesShared

/// A walk's phase in the terms the shared table speaks.
///
/// Free function rather than a property on `TrailWalkPhase?`, because the
/// absent phase is half the meaning here: a walk that has not started and one
/// that has finished are both `nil`, and an extension on `Optional` would read
/// as though it were a detail of the phase rather than of the session.
func hapticWalkState(for phase: TrailWalkPhase?) -> HapticWalkState {
    switch phase {
    case .none: .idle
    // No fix to wait for. A walk begins on a route the app is already
    // following, so it starts drawing immediately — which is why the shared
    // table answers `idle → running` as well as `idle → preparing`.
    case .following: .running
    case .paused: .paused
    }
}

/// What a walk's phase changing feels like, or nothing.
///
/// Silent on every ending. See the note at the top of this file.
func hapticFeedback(
    forWalkPhase old: TrailWalkPhase?,
    to new: TrailWalkPhase?
) -> HapticMoment? {
    guard new != nil else { return nil }
    return HapticMoment.walk(
        from: hapticWalkState(for: old),
        to: hapticWalkState(for: new)
    )
}

extension TrailWalkEnd {
    /// How a walk ended, as the hiker felt it.
    ///
    /// A walk too short to keep is a discard rather than a failure: nothing
    /// went wrong, and the confirmation the hiker just read said so in
    /// advance. A refusal is the failure — the walk is still under way and the
    /// alert behind this says to try again.
    var hapticMoment: HapticMoment {
        switch self {
        case .kept: .walkSaved
        case .discarded: .walkDiscarded
        case .refused: .walkFailed
        }
    }
}
