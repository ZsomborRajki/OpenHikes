//
//  TrailMapPanel.swift
//  OpenHikesWatch
//
//  The trail on Apple's own basemap, with the hiker on it.
//
//  ## Why a real map here, when the widget ships a rendered image
//
//  The objection recorded when this screen drew a bare line was transfer cost:
//  a basemap image is hundreds of kilobytes per trail across a Bluetooth link,
//  which is exactly what `TrailBasemapRenderer` pays on the phone so the iOS
//  widget can draw one. MapKit on watchOS costs none of that — the watch
//  fetches its own tiles, at the zoom the hiker is actually looking at, and
//  caches them itself. The objection was to *shipping tiles over the link*,
//  not to showing a map, and it does not apply to this.
//
//  What survives of it is the offline case, and the shape of the fallback is
//  the reassuring part: `MapPolyline` draws whether or not a tile ever
//  arrives, so a watch out of range shows the trail line on an empty basemap —
//  which is the glyph this replaces, less the framing. It degrades to the old
//  screen rather than to nothing.
//
//  ## What may read what
//
//  Both views here read the live position, so both are their own views rather
//  than pieces of ``TrailFollowView``'s body — the rule ``FollowFigures``
//  follows next door. A fix redraws a map and a dot, not the screen around
//  them.
//
//  The route and the dot are built by a function taking plain values rather
//  than by a view either of them owns: a `@MapContentBuilder` property on a
//  view reads that view's `@Environment`, and reaching for it from *another*
//  view's body would read an environment SwiftUI never injected.
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

/// The trail drawn on a basemap, framed on the hiker once there is one.
struct TrailMapPanel: View {
    /// How tall the map is drawn on the following screen.
    ///
    /// Taller than the line it replaces, because a basemap with nothing but a
    /// trail across it reads as a smear at glyph height, and still short
    /// enough to leave the first figures on screen with it on a 40 mm watch.
    private static let height = 104.0

    /// How much ground the followed camera shows.
    ///
    /// Close enough that the next bend is a shape rather than a wiggle, wide
    /// enough to see which way it goes before reaching it.
    private static let followDistanceMeters = 900.0

    let trail: WatchTrailPackage

    @Environment(WatchModel.self)
    private var model

    var body: some View {
        Map(position: .constant(camera), interactionModes: []) {
            trailMapContent(
                coordinates: trail.mapCoordinates,
                hiker: model.follow.matchedCoordinate,
                tint: trail.mapTint
            )
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: Self.height)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel("Map of \(trail.title)")
    }

    /// Framed on the hiker while there is a match, and on the whole trail
    /// before the first fix lands.
    ///
    /// `.automatic` rather than a region worked out here: it frames the
    /// `MapPolyline` itself, and does it without this view having to reason
    /// about a route straddling ±180°, where the extremes of the raw
    /// longitudes would zoom out to the whole planet.
    private var camera: MapCameraPosition {
        guard let hiker = model.follow.matchedCoordinate else { return .automatic }
        return .camera(MapCamera(centerCoordinate: hiker, distance: Self.followDistanceMeters))
    }
}

/// The same trail and the same dot, filling the screen and pannable.
///
/// Its own screen because the panel cannot be both: a `Map` that handles
/// gestures inside the following screen's `ScrollView` takes the drags meant
/// for the list it sits in, so the panel declares no interaction modes at all
/// and this is where a hiker who wants to look around goes.
struct TrailMapScreen: View {
    let trail: WatchTrailPackage

    @Environment(WatchModel.self)
    private var model

    /// Held rather than recomputed per fix, so a new match does not drag the
    /// map back from wherever the hiker has just panned it to.
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
        .navigationTitle(trail.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
