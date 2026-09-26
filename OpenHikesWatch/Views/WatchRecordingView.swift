//
//  WatchRecordingView.swift
//  OpenHikesWatch
//
//  Starting, pausing and stopping a walk, and the figures while it runs.
//
//  ## Two recordings, and which one the screen is about
//
//  A hike can be running on the phone or on this watch, and the screen shows
//  whichever it is. **A phone recording outranks an idle watch**, for the same
//  reason the repository instructions give for a recording outranking a
//  followed trail: it is the one that would be *lost*. A watch that hid a
//  running phone recording behind a Start button would invite exactly the
//  second hike that ruins the walk.
//
//  **What outranks both is a recording running on this watch**, and that is
//  not a contradiction of the rule above but the same rule applied where it
//  bites hardest. Starting on the watch is refused while the phone is
//  recording — see ``WatchModel/isPhoneRecording`` — but the reverse is
//  deliberately *not* guarded, because the phone is never told about a watch
//  recording while it runs. So the two can overlap, and when they do this
//  screen is the **only** place the watch's own recording can be paused or
//  stopped: hiding it would leave a workout session and a GPS feed running
//  with no way to end them. The phone's recording is reachable from the phone,
//  its Live Activity, Control Center and Siri; the watch's is reachable from
//  here and nowhere else.
//
//  ## Double Tap
//
//  Pause and resume answer it, on either recording — the watch's own and the
//  phone's mirrored one, since the screen shows exactly one of the two. A
//  hiker with a pole in each hand is who the gesture exists for, and pausing
//  is what they reach for at a stile or a view. Stop never answers it: a
//  gesture that can fire from a hand closing on a pole must not be the one
//  that ends the walk, and Start does not either, because an idle screen has
//  no walk to protect and a mistaken start is a second hike to delete.
//
//  ## What this body may read
//
//  `model.recorder.phase`, which changes when the hiker presses something.
//  The distance, the clock, the climb and the heart rate are all in
//  ``RecordingFigures``, the only view that reads ``WatchRecordingStats`` —
//  so a fix arriving redraws a handful of labels rather than this screen and
//  its buttons. That is the render-isolation rule from the repository
//  instructions, on the device where its cost is measured in battery rather
//  than in frames.
//

import OpenHikesShared
import SwiftUI

struct WatchRecordingView: View {
    @Environment(WatchModel.self)
    private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let phone = model.phoneRecording,
                   phone.isActive,
                   !model.recorder.phase.isActive {
                    PhoneRecordingPanel(recording: phone)
                } else {
                    watchRecording
                }
                if let refusal = model.commandRefusal {
                    RefusalNote(text: refusal) { model.acknowledgeRefusal() }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
        // Every moment this watch has to offer, off one phase — see
        // ``WatchRecordingHaptics``. On the body rather than in a leaf of its
        // own, because this body already reads `phase` and says above that it
        // may; the phone's screen needs the boundary and this one does not.
        .sensoryFeedback(trigger: model.recorder.phase) { old, new in
            HapticMoment.walk(
                from: old.hapticWalkState,
                to: new.hapticWalkState
            )?.feedback
        }
        // A command the phone would not carry out. The buttons that send one
        // are disabled until it answers, so this is the only way a hiker
        // learns the answer was no.
        .sensoryFeedback(trigger: model.commandRefusal) { _, refusal in
            refusal == nil ? nil : HapticMoment.walkFailed.feedback
        }
    }

    @ViewBuilder private var watchRecording: some View {
        VStack(spacing: 10) {
            switch model.recorder.phase {
            case .idle:
                idle
            case .preparing:
                ProgressView("Starting…")
            case .recording, .paused:
                RecordingFigures()
                controls
            case .saved(let walk):
                saved(walk)
            case .unsaved(let walk):
                UnsavedWalkPanel(walk: walk)
            case .failed(let message):
                failed(message)
            }
        }
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.startRecording(alongTrail: false) }
            } label: {
                Label("Start Hike", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            Text(
                """
                Records on this watch, with or without your iPhone. \
                The walk goes to your iPhone when it's back in range.
                """
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if model.recorder.phase == .paused {
                Button {
                    model.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(.green)
                .accessibilityLabel("Resume recording")
                .handGestureShortcut(.primaryAction)
            } else {
                Button {
                    model.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(.orange)
                .accessibilityLabel("Pause recording")
                .handGestureShortcut(.primaryAction)
            }
            Button {
                model.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .tint(.red)
            .accessibilityLabel("Stop recording")
        }
        if model.recorder.phase == .paused {
            Text("Paused. The ground you cover now isn't part of the walk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func saved(_ walk: WatchRecordedWalk) -> some View {
        VStack(spacing: 6) {
            Label("Walk Kept", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(WidgetFormat.length(meters: walk.distanceMeters))
                .font(.title3.monospacedDigit())
            Text(
                model.queuedWalkCount > 0
                    ? "Waiting for your iPhone. It'll go across on its own."
                    : "Sent to your iPhone."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button("Done") { model.recorder.acknowledge() }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 6) {
            Label("Not Recording", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("OK") { model.recorder.acknowledge() }
        }
    }
}

/// A stopped walk the watch could not write, and the only two ways out of it.
///
/// Retry rather than OK: this is the only copy of the walk, and an OK that
/// cleared it — which is what this screen used to offer — threw it away on a
/// tap that read as an acknowledgement. Discarding is offered too, because a
/// watch that stays full has to be able to record again, but behind a
/// confirmation of its own.
private struct UnsavedWalkPanel: View {
    let walk: WatchRecordedWalk

    @Environment(WatchModel.self)
    private var model
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(spacing: 6) {
            Label("Walk Not Saved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(WidgetFormat.length(meters: walk.distanceMeters))
                .font(.title3.monospacedDigit())
            Text("This watch is out of storage. Free up some space, then try again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { model.retrySavingWalk() }
            Button("Discard Walk", role: .destructive) { isConfirmingDiscard = true }
        }
        .confirmationDialog(
            "Discard this walk?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Walk", role: .destructive) { model.discardUnsavedWalk() }
        } message: {
            Text("It hasn't been saved anywhere, so it can't be recovered.")
        }
    }
}

/// The live figures, and the only view that reads them.
private struct RecordingFigures: View {
    @Environment(WatchModel.self)
    private var model

    var body: some View {
        let stats = model.recorder.stats
        return VStack(spacing: 4) {
            Text(WidgetFormat.duration(seconds: stats.activeSeconds))
                .font(.title2.monospacedDigit())
                .accessibilityLabel("Time walking")
            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    WatchFigure(title: "Distance", value: WidgetFormat.length(meters: stats.distanceMeters))
                    WatchFigure(title: "Climb", value: WidgetFormat.elevation(meters: stats.elevationGainMeters))
                }
                GridRow {
                    WatchFigure(title: "Pace", value: paceText(stats))
                    WatchFigure(title: "Heart", value: heartText(stats))
                }
            }
            if stats.fixCount == 0 {
                Text("Finding your position…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func paceText(_ stats: WatchRecordingStats) -> String {
        guard let speed = stats.averageSpeedMetersPerSecond else { return "—" }
        return WidgetFormat.speed(metersPerSecond: speed)
    }

    /// An em dash rather than a zero when the sensor has nothing to say — a
    /// sleeve over a watch reads as no heart rate, and drawing that as 0 bpm
    /// is the one number on this screen that would be alarming.
    private func heartText(_ stats: WatchRecordingStats) -> String {
        guard let beats = stats.heartRateBPM else { return "—" }
        return "\(Int(beats.rounded()))"
    }
}

/// The phone's recording, shown and driven from the wrist.
///
/// The only view that reads ``WatchModel/phoneRecording`` and the pending
/// command — the render-isolation rule this file's header states, applied to
/// the other feed. The figures the phone sends are exactly
/// `LiveRecordingReport`'s, so this shows what Siri says rather than a second
/// description assembled for a watch.
private struct PhoneRecordingPanel: View {
    let recording: WatchPhoneRecording

    @Environment(WatchModel.self)
    private var model

    var body: some View {
        VStack(spacing: 6) {
            Label("On Your iPhone", systemImage: "iphone")
                .font(.caption2)
                .foregroundStyle(.secondary)
            clock
            WatchFigure(
                title: "Distance",
                value: WidgetFormat.length(meters: recording.distanceMeters)
            )
            if let trail = recording.trailName {
                // Hedged the way the phone's own screen hedges it: a hiker who
                // stepped off the path a minute ago must not be told flatly
                // that they are still on it.
                Text(recording.isTrailNameStale ? "Last on \(trail)" : trail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            controls
        }
        // The phone's answer to a command sent from here, rather than the tap
        // that sent it. Silent when the recording ends: this watch is told
        // that the phone stopped and never whether it kept the walk, and a
        // guess either way would be worse than saying nothing.
        .sensoryFeedback(trigger: recording.state) { old, new in
            guard new != .idle else { return nil }
            return HapticMoment.walk(
                from: old.hapticWalkState,
                to: new.hapticWalkState
            )?.feedback
        }
    }

    /// Ticked by the system from an anchor rather than by a message a second.
    ///
    /// ``WatchPhoneRecording/clockAnchor`` is `nil` while paused, which is
    /// what makes a paused walk show a still number instead of a stopwatch
    /// running on a hike that is not.
    @ViewBuilder private var clock: some View {
        if let anchor = recording.clockAnchor {
            Text(anchor, style: .timer)
                .font(.title2.monospacedDigit())
                .accessibilityLabel("Time walking")
        } else {
            Text(WidgetFormat.duration(seconds: recording.elapsedSeconds))
                .font(.title2.monospacedDigit())
                .accessibilityLabel("Time walking")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if recording.state == .paused {
                button(.resume, "Resume recording on your iPhone", "play.fill", .green)
                    .handGestureShortcut(.primaryAction)
            } else {
                button(.pause, "Pause recording on your iPhone", "pause.fill", .orange)
                    .handGestureShortcut(.primaryAction)
            }
            button(.stop, "Stop recording on your iPhone", "stop.fill", .red)
        }
    }

    private func button(
        _ action: WatchRecordingCommand.Action,
        _ label: String,
        _ symbol: String,
        _ tint: Color
    ) -> some View {
        Button {
            model.command(action)
        } label: {
            if model.pendingCommand == action {
                ProgressView()
            } else {
                Image(systemName: symbol)
            }
        }
        .tint(tint)
        // Every button, not just the one pressed: the phone answers one
        // command at a time, and a hiker who tapped Pause and then Stop while
        // the first was in flight would be asking about a state neither of
        // them was issued against.
        .disabled(model.pendingCommand != nil)
        .accessibilityLabel(label)
    }
}

/// What the phone said when it would not do something.
///
/// Shown until it is read rather than for a few seconds: a hiker glancing at a
/// wrist under a waterproof will miss a banner, and the one sentence that
/// explains why their hike did not start is worth a tap to dismiss.
private struct RefusalNote: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.caption2)
                .multilineTextAlignment(.center)
            Button("OK", action: dismiss)
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(8)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}
