//
//  SceneLifecycleGate.swift
//  OpenHikes
//
//  Turns a stream of scene phases into the resign and active work that should
//  actually happen, once each per episode.
//
//  iOS runs `active → inactive → background` on the way out and
//  `background → inactive → active` on the way back, so a handler hung
//  naively off "not active" fires three times per round trip against one
//  genuine backgrounding. Two of those are wanted and one is not, and the
//  phase alone cannot tell them apart — both `.inactive` visits look
//  identical. What distinguishes them is whether `.background` has been seen
//  since the last `.active`, which is the single bit this type holds.
//
//  Pure and free of the model it serves so the rule can be asserted directly,
//  the same way `RecordingFixPolicy` and `TileNetworkPolicy` are.
//

import SwiftUI

/// What a scene-phase transition should cause.
nonisolated enum SceneLifecycleEvent: Equatable, Sendable {
    case becameActive
    /// A transition already accounted for by an earlier one in the same
    /// episode.
    case redundant
    case willResignActive
}

nonisolated struct SceneLifecycleGate: Sendable {
    private var hasReachedBackground = false

    /// The work `phase` should cause, given everything seen before it.
    ///
    /// `.inactive` on the way *out* resigns, because it is the earliest moment
    /// the app is certain it is losing the foreground and therefore where a
    /// save belongs. `.background` resigns too, because it is the last point a
    /// measured run can count on — UI automation backgrounds the app and only
    /// then terminates it, so dropping that one would lose the tail of every
    /// performance scenario. The `.inactive` step of *returning* is the
    /// redundant one: it arrives immediately before the app becomes active
    /// again and asks the recorder, the auto-save controller and the tile
    /// store to resign a foreground the app is in the act of regaining.
    mutating func event(for phase: ScenePhase) -> SceneLifecycleEvent {
        switch phase {
        case .active:
            hasReachedBackground = false
            return .becameActive
        case .background:
            hasReachedBackground = true
            return .willResignActive
        default:
            // `.inactive` and anything a future SDK adds between the two:
            // treated as resigning rather than ignored, because guessing wrong
            // in that direction costs a redundant idempotent save, and
            // guessing wrong in the other costs a walker their recording.
            return hasReachedBackground ? .redundant : .willResignActive
        }
    }
}
