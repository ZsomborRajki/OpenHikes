//
//  WalkControls.swift
//  OpenHikes
//
//  Pause, Resume and End for the walk under way, under the progress bar of
//  the hike being walked — the walk's counterpart of `RecordingCard`'s
//  controls, with the route's own tint rather than recording red.
//
//  The controls exist only once there is a walk to control: opening a trail
//  is not walking it, and this draws nothing until the first matched fix or
//  the title row's Start — ``WalkToggleButton`` — has started one. That
//  button's Pause and Resume carry the same titles as the ones here, so the
//  two are found by identifier: `walk-toggle` up there, `walk-controls-toggle`
//  here. On any *other* trail's detail while a walk is under way, it draws
//  the one-line notice naming the walk in progress instead.
//
//  Reads the session's coarse properties — which hike, which phase — and
//  nothing that moves per fix, so a fix that extends coverage redraws the
//  progress row beside this and not this. `walk-phase` and `walk-controls`
//  are distinct from `recording-phase` on purpose, as are the button titles:
//  the recording's *Pause* must never be found by a test looking for the
//  walk's, and vice versa.
//

import OpenHikesShared
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
    /// The phase a tap asked for and the store refused — see
    /// ``WalkPhaseRefusalAlert``.
    @State private var refusedPhase: TrailWalkPhase?

    var body: some View {
        Group {
            if session.walkedHikeID == hike.id, let phase = session.phase {
                VStack(spacing: 12) {
                    WalkPhaseRow(session: session, phase: phase, tint: hike.tintOpaque)
                    controls(for: phase)
                }
            } else if session.walkedHikeID != nil {
                Text("A hike is in progress on \(session.walkedHikeTitle). End it there to walk this trail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("walk-notice")
            }
        }
        .confirmationDialog(
            "End this hike?",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("End Hike", role: .destructive) {
                let end = session.end()
                // From the outcome rather than from the phase going absent:
                // kept, dropped and refused are three different pieces of news
                // and the phase carries none of them. See ``WalkHaptics``.
                end.hapticMoment.play()
                switch end {
                case let .kept(walk): onOpenWalk(walk)
                case .discarded: break
                case .refused: showEndRefusal = true
                }
            }
            Button("Cancel", role: .cancel) { /* no-op */ }
        } message: {
            Text("What it covered so far is kept as a record. A hike under 100 m is not.")
        }
        .alert("Could not end this hike", isPresented: $showEndRefusal) {
            Button("OK", role: .cancel) { /* no-op */ }
        } message: {
            Text("Its record could not be saved, so the hike is still under way. Try ending it again.")
        }
        .walkPhaseRefusalAlert($refusedPhase)
        // A walk that reached the end on its own has no tap to push its
        // summary from; this is what does it. A tapped End pushed from its
        // own action above, so only the automatic case is answered here.
        .onChange(of: session.lastEndedWalk) { _, ended in
            guard let ended, ended.hikeID == hike.id, ended.endReason == .reachedEnd else { return }
            // The one ending nobody asked for, and so the one most worth
            // feeling: a hiker who walked the last of the route learns it
            // without taking the phone out.
            HapticMoment.walkSaved.play()
            onOpenWalk(ended)
        }
        // The beginning and the middle. The endings are reported by the two
        // closures above, which know what kind of ending it was — see
        // ``WalkHaptics``.
        //
        // Scoped to the walked hike for the reason the `onChange` above is:
        // the session is one object and this view is on *every* hike's detail,
        // so two details alive in the stack at once would both answer the same
        // change. A phase can move without this screen being the one that
        // moved it — ``MovementReminderActions`` resumes a walk from a
        // notification — and that is the case where a hiker would feel the
        // same Resume twice.
        .sensoryFeedback(trigger: session.phase) { old, new in
            guard session.walkedHikeID == hike.id else { return nil }
            return hapticFeedback(forWalkPhase: old, to: new)?.feedback
        }
    }

    @ViewBuilder
    private func controls(for phase: TrailWalkPhase) -> some View {
        // Two `.glass` buttons side by side, in one container so they blend
        // as they meet — the recording's pair, in the route's tint.
        GlassStack(spacing: Self.controlGlassSpacing) {
            HStack {
                Button(phase.toggleTitle, systemImage: phase.toggleSymbol) {
                    refusedPhase = session.togglePhase(from: phase)
                }
                .glassButtonStyle()
                // The header's Start / Pause carries the same title, so the
                // two are told apart by identifier — see ``WalkToggleButton``.
                .accessibilityIdentifier("walk-controls-toggle")

                Button("End Hike", systemImage: "stop.fill") {
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

}

extension TrailWalkPhase {
    /// The Pause or Resume a walk in this phase offers.
    var toggleTitle: LocalizedStringKey {
        switch self {
        case .following: "Pause Hike"
        case .paused: "Resume Hike"
        }
    }

    var toggleSymbol: String {
        switch self {
        case .following: "pause.fill"
        case .paused: "play.fill"
        }
    }
}

extension TrailWalkSession {
    /// Pauses a following walk or resumes a paused one — the tap behind both
    /// ``WalkControls`` and the header's ``WalkToggleButton``.
    ///
    /// - Returns: the phase the tap asked for when the store refused it, for
    ///   ``WalkPhaseRefusalAlert`` to say so; `nil` when it was written down.
    ///   A change that *was* written down says nothing here: the phase moved,
    ///   and ``WalkControls``' `sensoryFeedback` has already answered it.
    func togglePhase(from phase: TrailWalkPhase) -> TrailWalkPhase? {
        let changed = switch phase {
        case .following: pause()
        case .paused: resume()
        }
        guard !changed else { return nil }
        HapticMoment.walkFailed.play()
        return phase == .following ? .paused : .following
    }
}

/// Says so when a Pause or Resume was not written down.
///
/// Without it a refused Pause is a button that does nothing: the walk is
/// deliberately left following, because that is what the sidecar still says,
/// and the row above goes on reading Hike Active.
private struct WalkPhaseRefusalAlert: ViewModifier {
    @Binding var refused: TrailWalkPhase?

    func body(content: Content) -> some View {
        content.alert(
            "Could not change this hike",
            isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })
        ) {
            Button("OK", role: .cancel) { /* no-op */ }
        } message: {
            Text(
                refused == .paused
                    ? "Pausing it could not be saved, so the hike is still under way. Try pausing it again."
                    : "Resuming it could not be saved, so the hike is still paused. Try resuming it again."
            )
        }
    }
}

extension View {
    func walkPhaseRefusalAlert(_ refused: Binding<TrailWalkPhase?>) -> some View {
        modifier(WalkPhaseRefusalAlert(refused: refused))
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
            Text(phase == .following ? "Hike Active" : "Hike Paused")
                .font(.headline)
            Spacer()
            if phase == .following, scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    PhaseClock(readout: HikeFormat.duration(session.activeSeconds()))
                }
            } else {
                PhaseClock(readout: HikeFormat.duration(session.activeSeconds()))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walk-phase")
    }
}
