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

/// The trail's line, and the system's own dot for the hiker.
///
/// `UserAnnotation` rather than the matched point this drew first, and the
/// difference matters most in the case the lock exists for. The matched dot is
/// the projection onto the trail, so it vanishes the moment a hiker steps off
/// it — which is exactly when somebody looks at their wrist to ask where they
/// are. The system's dot is where they actually stand, carries its own
/// accuracy halo, and is what the camera can follow.
///
/// The argument for snapping still holds where it was made: on a 2 pt line
/// with no basemap under it, a noisy fix beside the line reads as a hiker who
/// has left the trail. On a map, with terrain either side and a halo saying
/// how sure the receiver is, it reads as what it is. How far off the trail
/// they are is still said exactly, in the figures.
@MapContentBuilder
func trailMapContent(coordinates: [CLLocationCoordinate2D], tint: Color) -> some MapContent {
    MapPolyline(coordinates: coordinates)
        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    UserAnnotation()
}

extension WatchTrailPackage {
    var mapCoordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var mapTint: Color { Color(hex: tintHex) ?? .green }
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
            TrailMapFull(trail: trail, isShowingFigures: $isShowingFigures)
                .sheet(isPresented: $isShowingFigures) {
                    NavigationStack { TrailDetailView(trail: trail) }
                }
        } else {
            waiting
        }
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

/// The map itself: the route, the hiker, the lock that keeps the hiker
/// centred, and whatever the crown and a drag have done to the camera since.
///
/// Holds the camera, and everything that writes to it, for a reason the
/// repository's render-isolation rule makes: a followed camera is rewritten as
/// often as fixes arrive, and a screen that held it would redraw its buttons
/// and its sheet with every one. It reads no live state of its own — MapKit
/// moves its own dot — so a fix costs a camera write here and nothing above.
private struct TrailMapFull: View {
    /// How wide the floating buttons are drawn, and how far their ring is
    /// lifted out of the material behind them. A watch tap target does not go
    /// below 36 pt, and the ring is what keeps a circle findable over a light
    /// basemap, where the material alone all but disappears.
    private static let buttonSize = 36.0
    private static let ringOpacity = 0.2

    let trail: WatchTrailPackage

    @Binding var isShowingFigures: Bool

    /// Remembered across walks, and read here rather than passed in: this is
    /// the only view that draws a basemap.
    @AppStorage(WatchSettingsKey.mapStyle)
    private var styleID: String = WatchMapStyle.standard.rawValue

    /// `.automatic` frames the `MapPolyline`, which is what a trail should
    /// open as — the whole walk, before any of it has been done. It also keeps
    /// this view out of the business of a route straddling ±180°, where the
    /// extremes of the raw longitudes would zoom out to the whole planet.
    @State private var camera: MapCameraPosition = .automatic

    /// The last camera the map settled on, so unlocking can leave the view
    /// exactly where the lock left it rather than snapping back to the route.
    @State private var settled: MapCamera?

    var body: some View {
        Map(position: $camera) {
            trailMapContent(coordinates: trail.mapCoordinates, tint: trail.mapTint)
        }
        .mapStyle(style.mapStyle)
        .accessibilityLabel("Map of \(trail.title)")
        .onMapCameraChange(frequency: .onEnd) { context in
            settled = context.camera
            // A drag or a crown turn is MapKit telling us the hiker wants to
            // look somewhere else, and it says so by taking the position off
            // `.userLocation` itself. Letting the button follow that is what
            // stops it claiming a lock that is no longer holding.
            if camera.positionedByUser { lock = .off }
        }
        .overlay(alignment: .bottom) { buttons }
    }

    /// Whether the camera is locked to the hiker, and whether it turns with
    /// them.
    ///
    /// Three states rather than two, on one button, because a watch has room
    /// for one more button and not two. Off when a trail opens: the first
    /// question is "where does this go", which is the whole route, and the
    /// lock answers the second one.
    ///
    /// `heading` is what a hiker means by "which way now" — the map turns so
    /// the way ahead is up, and a fork that is left on the screen is left in
    /// front of them. North-up is kept as its own step because it is the one
    /// that can be checked against a printed map, and because a compass on a
    /// wrist swinging through a walking stride is not always worth following.
    private enum Lock {
        case off, north, heading

        var next: Self {
            switch self {
            case .off: .north
            case .north: .heading
            case .heading: .off
            }
        }

        var symbol: String {
            switch self {
            case .off: "location"
            case .north: "location.fill"
            case .heading: "location.north.line.fill"
            }
        }

        var label: String {
            switch self {
            case .off: "Follow your location"
            case .north: "Turn the map as you walk"
            case .heading: "Stop following your location"
            }
        }

        var isOn: Bool { self != .off }
    }

    @State private var lock: Lock = .off

    private var style: WatchMapStyle {
        WatchMapStyle(rawValue: styleID) ?? .standard
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            button(
                symbol: lock.symbol,
                label: lock.label,
                tint: lock.isOn ? Color.accentColor : .primary
            ) {
                lock = lock.next
                // Handing the follow to MapKit rather than re-centring on
                // every fix ourselves: it owns the dot, it knows when the
                // receiver has moved, it turns the map from the same heading
                // it draws the dot's wedge with, and it stops when the hiker
                // drags.
                let fallback = settled.map { MapCameraPosition.camera($0) } ?? .automatic
                camera = lock.isOn
                    ? .userLocation(followsHeading: lock == .heading, fallback: fallback)
                    : fallback
            }
            button(symbol: "list.bullet", label: "Trail figures", tint: .primary) {
                isShowingFigures = true
            }
        }
        .padding(.bottom, 4)
    }

    private func button(
        symbol: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(.ultraThinMaterial, in: .circle)
                .overlay(Circle().strokeBorder(.primary.opacity(Self.ringOpacity)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
