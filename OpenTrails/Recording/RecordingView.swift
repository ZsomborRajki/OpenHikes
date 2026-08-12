//
//  RecordingView.swift
//  OpenTrails
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingView: View {
    let recorder: HikeRecorder
    var mapController: MapController
    var onSaved: (Hike) -> Void
    var onDiscarded: () -> Void

    private var recordingFailure: RecordingFailure? {
        if case let .failed(failure) = recorder.phase {
            failure
        } else {
            nil
        }
    }

    private var showingFailure: Binding<Bool> {
        Binding(
            get: { recordingFailure != nil },
            set: { if !$0 { recorder.dismissFailure() } }
        )
    }

    private var failureNeedsSettings: Bool {
        recordingFailure == .locationDenied
            || recordingFailure == .preciseLocationRequired
    }

    var body: some View {
        RenderSignpost.mark("RecordingBody")
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RecordingHeader(recorder: recorder)
                RecordingRecoveryNotice(recorder: recorder)
                RecordingConditionsNotice(recorder: recorder)
                RecordingStatsGrid(stats: recorder.stats)
                RecordingControls(
                    recorder: recorder,
                    onSaved: onSaved,
                    onDiscarded: onDiscarded
                )
            }
            .padding()
        }
        .navigationTitle("Record Hike")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            mapController.followUser()
        }
        #if os(iOS)
        .onChange(of: recorder.phase) { _, phase in
            UIAccessibility.post(
                notification: .announcement,
                argument: phase.accessibilityTitle
            )
        }
        #endif
        .alert(isPresented: showingFailure, error: recordingFailure) {
            #if os(iOS)
            if failureNeedsSettings {
                Button("Open Settings") {
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else {
                        return
                    }
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button("OK", role: .cancel) {}
        }
    }
}

private struct RecordingRecoveryNotice: View {
    let recorder: HikeRecorder

    @ViewBuilder
    var body: some View {
        switch recorder.recoveryState {
        case .none:
            EmptyView()
        case .resumed:
            HStack(spacing: 10) {
                Label(
                    "Recording resumed after OpenTrails restarted.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.subheadline)
                Spacer()
                Button("Dismiss") {
                    recorder.dismissRecoveryNotice()
                }
                .font(.caption)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        case .needsDecision(let summary):
            VStack(alignment: .leading, spacing: 6) {
                Label("Recovered recording", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text(
                    "\(distance(summary.distanceMeters)) · "
                        + "\(summary.pointCount.formatted()) points · "
                        + "\(HikeFormat.duration(max(0, summary.lastUpdatedAt.timeIntervalSince(summary.startedAt))))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text("Resume it, stop to save it, or discard it below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Warns about system settings that quietly degrade a recording without
/// stopping it (`RECORD_HIKE.md` §13). Never blocks: a hike recorded in Low
/// Power Mode is worth far more than one refused on principle.
private struct RecordingConditionsNotice: View {
    let recorder: HikeRecorder

    var body: some View {
        #if os(iOS)
        if recorder.isActive, !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    #if os(iOS)
    private var warnings: [String] {
        var warnings: [String] = []
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            warnings.append(
                "Low Power Mode is on, so fixes may arrive less often than usual."
            )
        }
        if UIApplication.shared.backgroundRefreshStatus != .available {
            warnings.append(
                "Background App Refresh is off, so the track may be sparse while OpenTrails isn't open."
            )
        }
        return warnings
    }
    #endif
}

private struct RecordingHeader: View {
    let recorder: HikeRecorder

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phaseColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(phaseTitle)
                .font(.headline)
            Spacer()
            if recorder.sessionStartedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // The tick only says *when* to redraw; the value itself
                    // comes from the recorder's monotonic clock, so a system
                    // clock change mid-hike can't rewind the readout.
                    Text(HikeFormat.duration(recorder.elapsedSeconds()))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseTitle: String {
        recorder.phase.accessibilityTitle
    }

    private var phaseColor: Color {
        switch recorder.phase {
        case .recording:
            .red
        case .recovering, .waitingForFix, .saving:
            .orange
        case .paused:
            .secondary
        case .idle:
            .green
        case .failed:
            .red
        }
    }
}

private extension HikeRecorder.Phase {
    var accessibilityTitle: String {
        switch self {
        case .idle:
            "Ready"
        case .recovering:
            "Recovering"
        case .waitingForFix:
            "Finding GPS"
        case .recording:
            "Recording"
        case .paused:
            "Paused"
        case .saving:
            "Saving"
        case .failed:
            "Needs Attention"
        }
    }
}

private struct RecordingStatsGrid: View {
    let stats: RecordingStats

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            StatTile(label: "Distance", value: distance)
            StatTile(label: "Points", value: stats.pointCount.formatted())
            StatTile(label: "Avg Speed", value: averageSpeed)
            StatTile(label: "Accuracy", value: accuracy)
        }

        if let trail = stats.matchedTrailName {
            Text("Following: \(trail)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var distance: String {
        Measurement(value: stats.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var averageSpeed: String {
        guard let speed = stats.averageSpeedMetersPerSecond else { return "—" }
        return HikeFormat.speed(
            Measurement(value: speed, unit: UnitSpeed.metersPerSecond)
        )
    }

    private var accuracy: String {
        guard let accuracy = stats.horizontalAccuracy else { return "Searching…" }
        guard accuracy <= RecordingFixPolicy.maximumHorizontalAccuracy else {
            return "Weak signal"
        }
        return "±\(Int(accuracy.rounded())) m"
    }
}

private struct RecordingControls: View {
    let recorder: HikeRecorder
    var onSaved: (Hike) -> Void
    var onDiscarded: () -> Void

    @State private var showDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 12) {
            switch recorder.phase {
            case .idle:
                Button("Start Recording", systemImage: "record.circle") {
                    Task { await recorder.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

            case .recovering:
                ProgressView("Recovering recorded hike…")
                    .frame(maxWidth: .infinity)

            case .waitingForFix, .recording:
                HStack {
                    Button("Pause", systemImage: "pause.fill") {
                        recorder.pause()
                    }
                    .buttonStyle(.bordered)

                    stopButton
                }

            case .paused:
                HStack {
                    Button("Resume", systemImage: "play.fill") {
                        Task { await recorder.resume() }
                    }
                    .buttonStyle(.bordered)

                    stopButton
                }
                discardButton

            case .saving:
                ProgressView("Saving recorded hike…")
                    .frame(maxWidth: .infinity)

            case .failed:
                if recorder.isActive {
                    discardButton
                } else {
                    Button("Try Again") {
                        recorder.dismissFailure()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    await recorder.discard()
                    if recorder.phase == .idle {
                        onDiscarded()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recorded track cannot be recovered after it is discarded.")
        }
    }

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.fill") {
            Task {
                guard let hike = try? await recorder.stop() else { return }
                onSaved(hike)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private var discardButton: some View {
        Button("Discard Recording", role: .destructive) {
            showDiscardConfirmation = true
        }
        .buttonStyle(.bordered)
    }
}
