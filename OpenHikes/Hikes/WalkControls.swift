//
//  WalkControls.swift
//  OpenHikes
//
//  Pause, Resume and End for the walk under way, under the progress bar of
//  the hike being walked — in the shape `RecordingControls` has, with the
//  route's own tint rather than recording red.
//
//  The controls exist only once there is a walk to control: opening a trail
//  is not walking it, and this draws nothing until the first matched fix
//  has started one. On any *other* trail's detail while a walk is under
//  way, it draws the one-line notice naming the walk in progress instead.
//
//  Reads the session's coarse properties — which hike, which phase — and
//  nothing that moves per fix, so a fix that extends coverage redraws the
//  progress row beside this and not this. `walk-phase` and `walk-controls`
//  are distinct from `recording-phase` on purpose, as are the button titles:
//  the recording's *Pause* must never be found by a test looking for the
//  walk's, and vice versa.
//

import SwiftUI

struct WalkControls: View {
    /// How close the two glass controls have to come before they merge.
    private static let controlGlassSpacing: CGFloat = 8

    let hike: Hike
    let session: TrailWalkSession
    let onOpenWalk: (HikeWalk) -> Void

    @State private var showEndConfirmation = false
    /// A commit the store refused. The walk is still under way and its
    /// controls are still on screen — this is what says so, rather than
    /// letting a refusal read as a walk too short to keep.
    @State private var showEndRefusal = false
    /// The same for a phase the store refused, and the phase that tap asked
    /// for. Without it a refused Pause is a button that does nothing: the
    /// walk is deliberately left following, because that is what the sidecar
    /// still says, and the row above goes on reading Walk Active.
    @State private var showPhaseRefusal = false
    @State private var refusedPhase: TrailWalkPhase = .paused

    var body: some View {
        Group {
            if session.walkedHikeID == hike.id, let phase = session.phase {
                VStack(spacing: 12) {
                    WalkPhaseRow(session: session, phase: phase, tint: hike.tintOpaque)
                    controls(for: phase)
                }
            } else if session.walkedHikeID != nil {
                Text("A walk is in progress on \(session.walkedHikeTitle). End it there to walk this trail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("walk-notice")
            }
        }
        .confirmationDialog(
            "End this walk?",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Walk", role: .destructive) {
                switch session.end() {
                case let .kept(walk): onOpenWalk(walk)
                case .discarded: break
                case .refused: showEndRefusal = true
                }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("What it covered so far is kept as a record. A walk under 100 m is not.")
        }
        .alert("Could not end this walk", isPresented: $showEndRefusal) {
            Button("OK", role: .cancel) { /* no-op */ }
        } message: {
            Text("Its record could not be saved, so the walk is still under way. Try ending it again.")
        }
        .alert("Could not change this walk", isPresented: $showPhaseRefusal) {
            Button("OK", role: .cancel) { /* no-op */ }
        } message: {
            Text(
                refusedPhase == .paused
                    ? "Pausing it could not be saved, so the walk is still under way. Try pausing it again."
                    : "Resuming it could not be saved, so the walk is still paused. Try resuming it again."
            )
        }
        // A walk that reached the end on its own has no tap to push its
        // summary from; this is what does it. A tapped End pushed from its
        // own action above, so only the automatic case is answered here.
        .onChange(of: session.lastEndedWalk) { _, ended in
            guard let ended, ended.hikeID == hike.id, ended.endReason == .reachedEnd else { return }
            onOpenWalk(ended)
        }
    }

    @ViewBuilder
    private func controls(for phase: TrailWalkPhase) -> some View {
        // Two `.glass` buttons side by side, in one container so they blend
        // as they meet — the recording's pair, in the route's tint.
        GlassStack(spacing: Self.controlGlassSpacing) {
            HStack {
                switch phase {
                case .following:
                    Button("Pause Walk", systemImage: "pause.fill") {
                        refuse(.paused, unless: session.pause())
                    }
                    .glassButtonStyle()
                case .paused:
                    Button("Resume Walk", systemImage: "play.fill") {
                        refuse(.following, unless: session.resume())
                    }
                    .glassButtonStyle()
                }

                Button("End Walk", systemImage: "stop.fill") {
                    showEndConfirmation = true
                }
                .glassButtonStyle()
                // On the leaf rather than the stack: an identifier on a
                // container is pushed onto every descendant, and the buttons
                // are found by their own titles.
                .accessibilityIdentifier("walk-controls")
            }
        }
        .tint(hike.tintOpaque)
        .frame(maxWidth: .infinity)
    }

    /// Says so when a tap asking for `attempted` was not written down.
    private func refuse(_ attempted: TrailWalkPhase, unless changed: Bool) {
        guard !changed else { return }
        refusedPhase = attempted
        showPhaseRefusal = true
    }
}

/// The phase word, its dot, and the walk's clock.
///
/// The same arrangement as the recording header, for the same reasons: the
/// dot is a colour so the word beside it is spoken, and the clock is a 1 Hz
/// `TimelineView` that exists only while it is on screen. The clock reads
/// `session.activeSeconds()` — a function over ignored storage, so the tick
/// costs a `Text` and not an observation.
private struct WalkPhaseRow: View {
    let session: TrailWalkSession
    let phase: TrailWalkPhase
    let tint: Color

    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phase == .following ? tint : Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(phase == .following ? "Walk Active" : "Walk Paused")
                .font(.headline)
            Spacer()
            if phase == .following, scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    WalkClock(readout: HikeFormat.duration(session.activeSeconds()))
                }
            } else {
                WalkClock(readout: HikeFormat.duration(session.activeSeconds()))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walk-phase")
    }
}

/// The readout, storing the string rather than the session so SwiftUI diffs
/// what is on screen and the clock cannot silently freeze — the lesson
/// `RecordingClock` carries. `WalkClockTick` is the countable tick.
private struct WalkClock: View {
    let readout: String

    var body: some View {
        RenderSignpost.mark("WalkClockTick")
        return Text(readout)
            .font(.headline.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
