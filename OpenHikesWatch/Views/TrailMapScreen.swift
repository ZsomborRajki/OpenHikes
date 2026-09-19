//
//  TrailMapScreen.swift
//  OpenHikesWatch
//
//  A trail opens as a map. The figures are a button away.
//
//  ## Why the map is the screen rather than a panel on one
//
//  Because it is what a hiker opened the trail for. The figures answer "how
//  much is left"; the map answers "which way now", and that is the question
//  asked at a fork with a watch already raised. A panel above a list made the
//  hiker read the smaller of the two.
//
//  ## Why a real map at all, when the widget ships a rendered image
//
//  The objection recorded when this screen drew a bare line was transfer cost:
//  a basemap image is hundreds of kilobytes per trail across a Bluetooth link,
//  which is exactly what `TrailBasemapRenderer` pays on the phone so the iOS
//  widget can draw one. MapKit on watchOS costs none of that — the watch
//  fetches its own tiles, at the zoom the hiker is looking at, and caches them
//  itself. The objection was to *shipping tiles over the link*, not to showing
//  a map.
//
//  What survives of it is the offline case, and the fallback is reassuring:
//  `MapPolyline` draws whether or not a tile ever arrives, so a watch out of
//  range shows the trail line on an empty basemap — the glyph this replaced,
//  less the framing. It degrades to the old screen rather than to nothing.
//
//  ## What may read what
//
//  ``TrailMapFull`` reads the live position and is its own view for that
//  reason; this screen reads only the trail, which changes when a package
//  arrives. A fix redraws a map and a dot rather than the screen, the button
//  and the sheet around them.
//
//  The route and the dot are built by a function taking plain values rather
//  than by a view that owns them: a `@MapContentBuilder` property on a view
//  reads that view's `@Environment`, and reaching for it from another view's
//  body would read an environment SwiftUI never injected.
//

import MapKit
import OpenHikesShared
import SwiftUI

/// The trail's line, and the hiker on it when there is a match.
@MapContentBuilder
func trailMapContent(
    coordinates: [CLLocationCoordinate2D],
    hiker: CLLocationCoordinate2D?,
    tint: Color
) -> some MapContent {
    MapPolyline(coordinates: coordinates)
        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    if let hiker {
        Annotation("You", coordinate: hiker) {
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(tint, lineWidth: 3))
                .shadow(radius: 1)
        }
    }
}

extension WatchTrailPackage {
    var mapCoordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var mapTint: Color { Color(hex: tintHex) ?? .green }
}

extension WatchFollowState {
    /// The point on the *trail* the hiker was matched to, rather than the
    /// coordinate their receiver reported.
    ///
    /// The same choice `SharedTrailSnapshot.LiveFix` makes. A dot drawn at the
    /// raw fix sits beside the line whenever GPS is noisy, which on a line
    /// this thin reads as a hiker who has left the trail.
    ///
    /// Read straight off the match rather than worked back out of its distance
    /// along the trail. Nothing here could do the second one correctly: it
    /// would have to turn metres into a point on a line whose points are not
    /// evenly spaced, and the cumulative distances that make that exact belong
    /// to ``WatchRouteTracker``, which has already walked them to find this
    /// very point.
    var matchedCoordinate: CLLocationCoordinate2D? {
        guard let position, position.isOnTrail else { return nil }
        return CLLocationCoordinate2D(
            latitude: position.trailCoordinate.latitude,
            longitude: position.trailCoordinate.longitude
        )
    }
}

/// One trail, opened: the map, and the way to its figures.
///
/// Owns the whole trail's lifetime on screen — asking the phone for the
/// geometry, starting the position feed, and stopping it on the way out. The
/// figures are a *sheet* rather than a push for that reason: a push takes this
/// view off screen, `onDisappear` would stop the feed the figures are made of,
/// and the two would fight over it every time the button was pressed.
struct TrailMapScreen: View {
    let hikeID: UUID
    let name: String

    @Environment(WatchModel.self)
    private var model

    /// How wide the figures button is drawn, and how far its ring is lifted
    /// out of the material behind it. A watch tap target does not go below
    /// 36 pt, and the ring is what keeps the circle findable over a light
    /// basemap, where the material alone all but disappears.
    private static let buttonSize = 36.0
    private static let ringOpacity = 0.2

    @State private var isShowingFigures = false

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                model.selectTrail(hikeID)
                model.startFollowing()
            }
            .onDisappear {
                // Only when nothing is recording. A recording owns the feed
                // and outlives this screen — which is the whole point of it.
                if !model.recorder.phase.isActive { model.stopFollowing() }
            }
    }

    @ViewBuilder private var content: some View {
        if let trail = model.trail, trail.hikeID == hikeID, trail.isDrawable {
            TrailMapFull(trail: trail)
                .overlay(alignment: .bottom) { figuresButton }
                .sheet(isPresented: $isShowingFigures) {
                    NavigationStack { TrailDetailView(trail: trail) }
                }
        } else {
            waiting
        }
    }

    /// Over the map rather than under it, because the map is the screen: a row
    /// beneath would cost it the height, and this is pressed once a walk
    /// rather than once a minute.
    private var figuresButton: some View {
        Button {
            isShowingFigures = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.body.weight(.semibold))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(.ultraThinMaterial, in: .circle)
                .overlay(Circle().strokeBorder(.primary.opacity(Self.ringOpacity)))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
        .accessibilityLabel("Trail figures")
    }

    private var waiting: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(
                model.link.isReachable
                    ? "Fetching this trail from your iPhone…"
                    : "Waiting for your iPhone to come back in range…"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }
}

/// The map itself: the route, the hiker, and whatever the crown and a drag
/// have done to the camera since.
private struct TrailMapFull: View {
    let trail: WatchTrailPackage

    @Environment(WatchModel.self)
    private var model

    /// Held rather than recomputed per fix, so a match arriving does not drag
    /// the map back from wherever the hiker has just moved it to. `.automatic`
    /// frames the `MapPolyline` to begin with, which also keeps this view out
    /// of the business of a route straddling ±180°, where the extremes of the
    /// raw longitudes would zoom out to the whole planet.
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            trailMapContent(
                coordinates: trail.mapCoordinates,
                hiker: model.follow.matchedCoordinate,
                tint: trail.mapTint
            )
        }
        .mapStyle(.standard(elevation: .flat))
        .accessibilityLabel("Map of \(trail.title)")
    }
}
