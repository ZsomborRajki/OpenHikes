//
//  HapticWalkState.swift
//  OpenHikesShared
//
//  The one table that says what a walk changing state feels like, shared by
//  the two recorders that have no other code in common.
//
//  `HikeRecorder.Phase` lives in the app and `WatchRecorder.Phase` lives in
//  the watch app; neither can see the other, and the watch has no test bundle
//  at all — see *The watch app* in the instructions file. Writing the mapping
//  twice would mean the two drifting silently, on exactly the surface where
//  agreement is the feature: a hiker records on the wrist one day and in a
//  pocket the next, and Pause has to feel like Pause both times.
//
//  So each phase projects into ``HapticWalkState`` and one transition table
//  answers both. The projections are a line per case and live beside their own
//  phase; everything that could be got wrong is here, where `swift test`
//  reaches it on the macOS host.
//
//  The table is driven by the *transition* rather than by the destination, and
//  that is load-bearing rather than tidy. On iOS a saved walk and a discarded
//  one both end at `.idle` — ``HikeRecorder/resetSession()`` is the single path
//  out of a session — so the destination alone cannot tell "kept" from "thrown
//  away". What separates them is where they came from: a save is the only way
//  to reach `.idle` through `.saving`.
//

/// A walk's state, in the only terms the haptic table needs.
///
/// Coarser than either recorder's own phase and deliberately not a substitute
/// for it. Nothing here drives what is on screen; the phases keep saying that.
public enum HapticWalkState: String, CaseIterable, Equatable, Sendable {
    /// Could not be started, continued or kept.
    case failed = "failed"
    /// Written down, and the result is on screen. The watch ends here; iOS
    /// returns to ``idle`` instead and is told apart by ``saving``.
    case finished = "finished"
    /// No walk under way.
    case idle = "idle"
    /// Not drawing a line, and not over.
    case paused = "paused"
    /// Asked for, and not yet drawing a line — waiting on a fix, on Health, or
    /// on the hiker answering a permission prompt.
    case preparing = "preparing"
    /// A walk from a previous launch is being pieced back together. Silent in
    /// both directions, because the hiker did not ask for it and the recording
    /// screen says so in words.
    case recovering = "recovering"
    /// Over, and the hiker is being asked about the route before it is kept.
    case reviewing = "reviewing"
    /// Drawing a line.
    case running = "running"
    /// Over, and being written down.
    case saving = "saving"
}

public extension HapticMoment {
    /// What a walk moving from `old` to `new` feels like, or nothing.
    ///
    /// Nothing is the common answer, and it is the important half: a table
    /// with an opinion about every pair would buzz through a recovery, a
    /// redraw and every internal step of a save. Only the transitions a hiker
    /// would describe out loud are answered.
    static func walk(
        from old: HapticWalkState,
        to new: HapticWalkState
    ) -> HapticMoment? {
        // A state that did not change is not an event, whatever else is true.
        // SwiftUI will not call a `sensoryFeedback` trigger for an equal value,
        // but the projections into this type are lossy — `waitingForFix` and
        // `recovering` are one state here — so two *different* phases can
        // arrive as one state, and that is a redraw rather than news.
        guard old != new else { return nil }
        switch (old, new) {
        // A walk failed. Answered first, so a failure reached from any state at
        // all is reported as one — including out of a recovery, which is
        // otherwise silent below. A hiker who did not ask for the recovery
        // still needs to know their walk is not being recorded.
        case (_, .failed):
            return .walkFailed

        // Nothing else about a recovery was asked for, so nothing is said.
        case (.recovering, _), (_, .recovering):
            return nil

        // Asked for. `.running` as well as `.preparing`, because a walk that is
        // already on a trail — ``TrailWalkSession`` — has no fix to wait for
        // and starts drawing immediately.
        case (.idle, .preparing), (.idle, .running):
            return .walkBegan
        case (.failed, .preparing), (.failed, .running):
            return .walkBegan

        // The first accepted fix.
        case (.preparing, .running):
            return .trackingBegan

        case (.running, .paused):
            return .walkPaused
        case (.paused, .running):
            return .walkResumed

        // Kept. Two shapes of the same news: the watch stops on a screen
        // showing the walk, and iOS goes back to an idle recorder.
        case (_, .finished), (.saving, .idle):
            return .walkSaved

        // Thrown away. Everything reaching `.idle` without passing through
        // `.saving` — including from `.reviewing`, where Discard sits beside
        // the review controls and is the case this clause exists for.
        case (.running, .idle), (.paused, .idle), (.reviewing, .idle):
            return .walkDiscarded

        // Acknowledging a result, and every internal step of a save: the hiker
        // has already been told.
        default:
            return nil
        }
    }
}
