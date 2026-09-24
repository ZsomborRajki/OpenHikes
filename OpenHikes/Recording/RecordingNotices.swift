//
//  RecordingNotices.swift
//  OpenHikes
//
//  The two notices the recording card carries under its title row: a
//  recording recovered after a relaunch, and the system settings that thin a
//  track out without stopping it.
//

import OpenHikesData
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingRecoveryNotice: View {
    let recorder: HikeRecorder

    private let noticePadding: CGFloat = 12
    private let noticeRadius: CGFloat = 12
    private let noticeSpacingResumed: CGFloat = 10
    private let noticeSpacingDecision: CGFloat = 6

    @ViewBuilder var body: some View {
        switch recorder.recoveryState {
        case .absent: EmptyView()
        case .resumed:
            HStack(spacing: noticeSpacingResumed) {
                Label(
                    "Recording resumed after OpenHikes restarted.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.subheadline)
                Spacer()
                Button("Dismiss") {
                    recorder.dismissRecoveryNotice()
                }
                .font(.caption)
            }
            .padding(noticePadding)
            // Orange-tinted glass rather than a flat 12% orange wash: the
            // notice keeps the colour that says "recovered" while staying a
            // card that floats over the screen rather than a block painted
            // onto it.
            .glassSurface(
                .regular.tint(.orange),
                in: .rect(cornerRadius: noticeRadius)
            )
        case .needsDecision(let summary):
            VStack(alignment: .leading, spacing: noticeSpacingDecision) {
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
            .padding(noticePadding)
            .glassSurface(
                .regular.tint(.orange),
                in: .rect(cornerRadius: noticeRadius)
            )
        }
    }

    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Warns about system settings that quietly degrade a recording without
/// stopping it. Never blocks: a hike recorded in Low Power Mode is worth far
/// more than one refused on principle.
struct RecordingConditionsNotice: View {
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
        // The energy profile's own words rather than a separate sentence about
        // Low Power Mode: the profile is what the app did about it, and two
        // messages about the same condition would contradict each other.
        if let reason = recorder.energyProfile.reason {
            warnings.append(reason)
        }
        if UIApplication.shared.backgroundRefreshStatus != .available {
            warnings.append(
                "Background App Refresh is off, so the track may be sparse while OpenHikes isn't open."
            )
        }
        return warnings
    }
    #endif
}
