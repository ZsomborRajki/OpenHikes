//
//  InterruptedWalkPanel.swift
//  OpenHikesWatch
//
//  What the Record screen shows for a walk the last process never finished:
//  the walk and the three things that can become of it, or, when its journal
//  could not be read, only that it is there.
//
//  Views of their own rather than parts of ``WatchRecordingView``, so that a
//  Discard the disk refused can be said on the panel it was pressed on. The
//  recorder keeps the walk when the journal will not go (#1573), and a button
//  that did nothing, silently, would read as a button that is broken. The
//  line lasts as long as the panel: a phase that leaves and comes back draws
//  a new one, with nothing to say.
//

import OpenHikesShared
import SwiftUI

/// A walk the last process never finished, and the three things that can
/// become of it.
///
/// The time it stopped is said, because what is kept ends there: nothing was
/// recorded while the watch was not running, and a Continue picks up from
/// where the hiker is now rather than drawing a line across the gap.
struct InterruptedWalkPanel: View {
    let recovered: WatchRecoveredRecording

    @Environment(WatchModel.self) private var model
    @State private var isDiscardRefused = false

    var body: some View {
        VStack(spacing: 6) {
            Label("Hike Interrupted", systemImage: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)
            Text(WidgetFormat.length(meters: recovered.accumulator.distanceMeters))
                .font(.title3.monospacedDigit())
            Text("Recording stopped at \(recovered.lastRecordedAt, style: .time). Everything before then is kept.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.continueInterruptedRecording() }
            } label: {
                Label("Continue", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(model.isPhoneRecording)
            Button("Save Hike") { Task { await model.saveInterruptedRecording() } }
            Button("Discard", role: .destructive) {
                isDiscardRefused = !model.discardInterruptedRecording()
            }
            if isDiscardRefused { DiscardRefusedNote() }
        }
    }
}

/// A walk the last process never finished whose journal could not be read,
/// so all there is to say is that it is there (#1573).
///
/// Read again whenever the app comes to the front, and on Try Again. Discard
/// is the way out for a journal that never reads, as it is for one that does.
struct UnreadableJournalPanel: View {
    @Environment(WatchModel.self) private var model
    @State private var isDiscardRefused = false

    var body: some View {
        VStack(spacing: 6) {
            Label("Hike Interrupted", systemImage: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)
            Text("This watch can’t read the interrupted hike right now. Try again, or discard it to record a new one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { model.checkInterruptedRecordingAgain() }
            Button("Discard", role: .destructive) {
                isDiscardRefused = !model.discardInterruptedRecording()
            }
            if isDiscardRefused { DiscardRefusedNote() }
        }
    }
}

/// Said under a Discard the disk refused: the walk is still here, and so is
/// the choice.
struct DiscardRefusedNote: View {
    var body: some View {
        Text("This watch couldn’t discard the hike. Try again later.")
            .font(.caption2)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
    }
}
