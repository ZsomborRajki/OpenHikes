//
//  TrailWidgetAccessories.swift
//  OpenWidget
//

import OpenHikesShared
import SwiftUI
import WidgetKit

struct AccessoryCircularContent: View {
    let entry: TrailWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            if let progress = snapshot.progressFraction {
                Gauge(value: progress) {
                    Image(systemName: "figure.hiking")
                        .accessibilityHidden(true)
                } currentValueLabel: {
                    Text("\(Int((progress * 100).rounded()))%")
                }
                .tint(Color(hex: snapshot.tintHex) ?? .green)
            } else {
                Image(systemName: "figure.hiking")
                    .font(.title2)
                    .accessibilityHidden(true)
            }
        } else if let recording = entry.recordingSnapshot {
            Image(systemName: recording.isCapturingFixes ? "figure.hiking" : "pause.fill")
                .font(.title2)
                .foregroundStyle(recording.isCapturingFixes ? .red : .secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "figure.hiking")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

struct AccessoryRectangularContent: View {
    let entry: TrailWidgetEntry

    private var title: String {
        entry.snapshot?.title ?? entry.recordingSnapshot?.title ?? "OpenHikes"
    }

    private var status: String {
        entry.snapshot?.statusText ?? entry.recordingSnapshot?.statusText ?? "Select a trail"
    }

    private var progress: Double? {
        entry.snapshot?.progressFraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress {
                TrailWidgetProgressBar(
                    fraction: progress,
                    tint: Color(hex: entry.snapshot?.tintHex ?? "") ?? .green,
                    onMap: false
                )
            }
        }
        .padding(.horizontal, 2)
    }
}

struct AccessoryInlineContent: View {
    let entry: TrailWidgetEntry

    var body: some View {
        Text(
            entry.snapshot.map { "\($0.title) · \($0.statusText)" }
                ?? entry.recordingSnapshot.map { "\($0.title) · \($0.statusText)" }
                ?? "Select a trail in OpenHikes"
        )
        .lineLimit(1)
    }
}
