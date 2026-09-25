//
//  WalkControls.swift
//  OpenHikes
//
//  The walk under way, under the progress bar of the hike being walked: its
//  phase and clock, and End and Save Hike.
//
//  Pause and Resume are not here. They are the navigation bar's
//  ``WalkToggleButton``, which is on screen at every detent, and a second
//  copy of them in the scroll view was one button too many (#679). End is
//  drawn like *Find Photos of This Hike* — a section's own action, leading
//  aligned — and says in its title that ending keeps the walk as a record.
//
//  The controls exist only once there is a walk to control: opening a trail
//  is not walking it, and this draws nothing until the first matched fix or
//  the navigation bar's Start has started one. On any *other* trail's detail
//  while a walk is under way, it draws the one-line notice naming the walk in
//  progress instead.
//
//  Reads the session's coarse properties — which hike, which phase — and
//  nothing that moves per fix, so a fix that extends coverage redraws the
//  progress row beside this and not this. `walk-phase` and `walk-controls`
//  are distinct from `recording-phase` on purpose, as are the button titles:
//  the recording's *Stop* must never be found by a test looking for the
//  walk's End, and vice versa.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

struct WalkControls: View {
    let hike: Hike
    let session: TrailWalkSession
    let onOpenWalk: (HikeWalk) -> Void

    @State private var showEndConfirmation = false
    /// A commit the store refused. The walk is still under way and its
    /// controls are still on screen — this is what says so, rather than
    /// letting a refusal read as a walk too short to keep.
    @State private var showEndRefusal = false

    var body: some View {
        Group {
            if session.walkedHikeID == hike.id, let phase = session.phase {
                VStack(alignment: .leading, spacing: 12) {
                    WalkPhaseRow(session: session, phase: phase, tint: hike.tintOpaque)
                    endButton
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
            Button("End and Save Hike", role: .destructive) {
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

    /// Drawn the way *Find Photos of This Hike* is, in the app's accent
    /// rather than the route's tint, so the two section actions on this
    /// screen read as one kind of control.
    private var endButton: some View {
        Button("End and Save Hike", systemImage: "stop.fill") {
            showEndConfirmation = true
        }
        .sectionActionButtonStyle()
        // On the leaf rather than the stack: an identifier on a container is
        // pushed onto every descendant, and the phase row is found by its own.
        .accessibilityIdentifier("walk-controls")
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
