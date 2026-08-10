//
//  TrailWatchView.swift
//  OpenWatch Watch App
//
//  Deliberately minimal — everything here can already be reached from the
//  complication, so this is a fallback for the rare case someone opens the
//  app directly, not a designed-for surface in its own right.
//

import SwiftUI
import OpenTrailsShared

struct TrailWatchView: View {
    let bridge: WatchConnectivityBridge

    var body: some View {
        if let snapshot = bridge.snapshot {
            content(for: snapshot)
        } else {
            emptyState
        }
    }

    private func content(for snapshot: SharedTrailSnapshot) -> some View {
        VStack(spacing: 4) {
            Text(snapshot.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            TrailGlyphView(
                polyline: snapshot.polyline,
                liveFix: snapshot.liveFix?.coordinate,
                tint: Color(hex: snapshot.tintHex) ?? .green,
                lineWidth: 3
            )
            Text(snapshot.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.hiking")
                .foregroundStyle(.secondary)
            Text("Select a trail on your iPhone")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    TrailWatchView(bridge: WatchConnectivityBridge())
}
