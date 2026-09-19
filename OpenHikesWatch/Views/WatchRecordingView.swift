//
//  WatchRecordingView.swift
//  OpenHikesWatch
//
//  Starting, pausing and stopping a walk, and the figures while it runs.
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
                case .failed(let message):
                    failed(message)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
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
            } else {
                Button {
                    model.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(.orange)
                .accessibilityLabel("Pause recording")
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
