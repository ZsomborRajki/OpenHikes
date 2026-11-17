//
//  JunctionCueBanner.swift
//  OpenHikesWatch
//
//  The junction warning the watch has just tapped, over whatever screen is up.
//
//  The only view that reads ``WatchJunctionCue``, so a cue arriving redraws
//  this and nothing above it — `WatchRootView`, which places it, reads
//  nothing (*Render isolation* in `AGENTS.md`).
//

import OpenHikesShared
import SwiftUI

struct JunctionCueBanner: View {
    /// How long a cue stays up. Long enough to raise a wrist after the tap
    /// and read it; the cue at the junction replaces the one before it.
    private static let shownFor: Duration = .seconds(10)
    private static let cornerRadius: CGFloat = 14

    @Environment(WatchModel.self) private var model

    var body: some View {
        if let shown = model.junctionCue.shown {
            HStack(spacing: 8) {
                Image(systemName: shown.maneuver.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.maneuver.instruction)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let distance = shown.distance {
                        Text(distance)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Hides this warning."))
            .onTapGesture { model.junctionCue.dismiss(shown.id) }
            .task(id: shown.id) {
                // A banner's own time on screen, not a barrier anything
                // waits on.
                try? await Task.sleep(for: Self.shownFor)
                model.junctionCue.dismiss(shown.id)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
