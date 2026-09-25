//
//  HikeActionRow.swift
//  OpenHikes
//
//  The row of equal buttons under a hike's title — the place-card row where
//  Apple Maps puts Directions, Call and Website: Zoom, Follow, Offline and
//  Share.
//
//  Its own view rather than a property of ``HikeDetailView``, so the follow
//  switch's state and the share payload are read here and a flip of either
//  redraws this row and nothing above it.
//
//  Starting a walk is not here. That is the navigation bar's
//  ``WalkToggleButton``, which is on screen at every detent.
//

import OpenHikesData
import SwiftUI

struct HikeActionRow<OfflineTile: View>: View {
    let hike: Hike
    let onZoom: () -> Void
    /// ``OfflineDownloadButton``, or nothing for a map that cannot bulk
    /// download. Handed in because the download belongs to the screen, which
    /// owns the downloader and the tile source it captures.
    @ViewBuilder let offlineTile: OfflineTile

    private var hasRoute: Bool { hike.pointCount > 1 }

    var body: some View {
        // One glass sample for the row rather than one per tile, and the
        // tiles blend into each other as the row tightens at large text
        // sizes — see ``GlassStack``.
        GlassStack(spacing: ActionTileMetrics.glassSpacing) {
            HStack(spacing: 12) {
                zoomTile
                followTile
                offlineTile
                shareTile
            }
        }
    }

    private var zoomTile: some View {
        Button(action: onZoom) {
            tile(icon: "scope", title: "Zoom")
        }
        .buttonStyle(.plain)
        .disabled(!hasRoute)
    }

    /// Shows the live position on the chart and the map, and lets a matched
    /// fix start a walk. Drawn filled while it is on, like the switch it is —
    /// and it *is* a switch to VoiceOver, where its name stays the whole
    /// phrase the visible *Follow* is short for.
    private var followTile: some View {
        Toggle(isOn: followBinding) {
            Text("Follow This Trail")
        }
        .toggleStyle(FollowTileToggleStyle())
        .accessibilityIdentifier("follow-trail-toggle")
        .disabled(!hasRoute)
    }

    /// Hands the route to the share sheet as a `.gpx` file — the export half
    /// of the import this app already does.
    ///
    /// The payload is a `Sendable` ``GPXExport/Track`` snapshot rather than the
    /// `Hike`: `ShareLink` passes the exporter to the system, which calls it
    /// off the main actor, where a `@Model` must not be read. Building the
    /// snapshot is a retain of the route's storage, not a copy of it, and the
    /// XML itself is written only once a destination is picked.
    ///
    /// The preview carries an icon so the sheet's header reads as the document
    /// being sent rather than as a bare line of text.
    private var shareTile: some View {
        ShareLink(
            item: HikeGPXFile(track: GPXExport.Track(hike: hike)),
            preview: SharePreview(
                hike.displayTitle,
                icon: Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            )
        ) {
            tile(icon: "square.and.arrow.up", title: "Share")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share hike")
        .disabled(!hasRoute)
    }

    private var followBinding: Binding<Bool> {
        Binding(
            get: { hike.autoFollowEnabled },
            set: { hike.autoFollowEnabled = $0 }
        )
    }

    private func tile(icon: String, title: LocalizedStringKey) -> some View {
        ActionTile {
            Image(systemName: icon)
                .font(.title3)
                .accessibilityHidden(true)
            Text(title).font(.caption2.weight(.medium))
        }
    }
}

/// *Follow* as an action tile: outlined while off, filled and reading
/// *Following* while on.
///
/// A `ToggleStyle` rather than a button that flips a flag, so the control
/// keeps the switch semantics a `Toggle` carries — its on/off value and the
/// label it is announced by — whatever it looks like.
private struct FollowTileToggleStyle: ToggleStyle {
    @Environment(\.isEnabled)
    private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ActionTile(
                tint: isEnabled ? .accentColor : .secondary,
                isProminent: configuration.isOn && isEnabled
            ) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(configuration.isOn ? "Following" : "Follow")
                    .font(.caption2.weight(.medium))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
