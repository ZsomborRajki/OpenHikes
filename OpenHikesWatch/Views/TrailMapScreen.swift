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
    // A dark casing under the coloured line, drawn first so the line sits on
    // top of it. The phone's `TrailStroke` has done this since the beginning
    // and the watch was the one place going without: a 3 pt line in a hike's
    // own tint is legible over grass and invisible over a lake, a road, or a
    // shaded north face, and the hiker does not get to choose which of those
    // the next kilometre is drawn on. The casing is what makes the route the
    // same line everywhere.
    MapPolyline(coordinates: coordinates)
        .stroke(
            .black.opacity(casingOpacity),
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        )
    MapPolyline(coordinates: coordinates)
        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    // Which end is which, which a line alone never says. On an out-and-back
    // the two are the same place and one marker covers the other, which is
    // the truth about an out-and-back; on a loop they are the gate you parked
    // at, and on a point-to-point they are the difference between walking the
    // route and walking it backwards.
    //
    // The titles are hidden rather than left off: a marker needs a name for
    // the accessibility tree and a watch screen has no room to print one. Two
    // words beside two 8 pt marks cost more of the map than the marks do.
    if let start = coordinates.first {
        Annotation("Start", coordinate: start) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
        .annotationTitles(.hidden)
    }
    if let finish = coordinates.last, coordinates.count > 1 {
        Annotation("Finish", coordinate: finish) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .annotationTitles(.hidden)
    }
    UserAnnotation()
}

/// How dark the casing under the route is.
///
/// Enough to separate the line from whatever it crosses, and not so much that
/// the route reads as a black line with a coloured core on a dark basemap.
private let casingOpacity = 0.45

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
    /// How wide the floating buttons are *drawn*, and how far their ring is
    /// lifted out of the material behind them. The ring is what keeps a circle
    /// findable over a light basemap, where the material alone all but
    /// disappears.
    private static let buttonSize = 36.0
    private static let ringOpacity = 0.2
    /// How much invisible target is added around each one.
    ///
    /// The circle stays 36 pt because two bigger ones would cover the trail
    /// they are drawn over, but a finger on a moving wrist is not a 36 pt
    /// instrument — the tappable shape is 52 pt and the drawn one is not.
    private static let buttonPadding = 8.0

    /// What a hiker might actually walk to, and nothing else.
    ///
    /// Water and a lavatory are the two a long day turns on; a car park and a
    /// bus stop are how the walk starts and ends; the rest is shelter and the
    /// numbers worth having when something has gone wrong. The default draws
    /// everything a city has, on 44 mm, over the trail.
    private static let hikingPointsOfInterest: [MKPointOfInterestCategory] = [
        .nationalPark, .park, .campground, .beach, .marina,
        .restroom, .parking, .publicTransport,
        .cafe, .restaurant, .hotel,
        .hospital, .fireStation, .police,
    ]

    /// Apple's map, tuned as far as a hiking map as it goes.
    ///
    /// Realistic elevation because the relief is the half of a hiking map
    /// Apple's vector layer does have: a trail contouring round a spur looks
    /// like what it is rather than like a wiggle. Muted emphasis puts the
    /// roads behind the route drawn over them.
    ///
    /// **There is no satellite option, and that is not an omission.** Apple's
    /// own note on `MapStyle`: "In watchOS, depending on rendering
    /// calculations, MapKit may render the map using the Standard map style
    /// rather than requested Hybrid or Imagery styles." Measured on a watch
    /// simulator, `.hybrid` came back pixel-identical to this — so the switch
    /// that offered it was a control that did nothing, which is worse than not
    /// offering the choice. Tiles of our own are not a way round it either:
    /// `MKTileOverlay`, `MKTileOverlayRenderer` and `MKMapView` are all
    /// `API_UNAVAILABLE(watchos)`.
    private static let hikingStyle: MapStyle = .standard(
        elevation: .realistic,
        emphasis: .muted,
        pointsOfInterest: .including(hikingPointsOfInterest)
    )

    let trail: WatchTrailPackage

    @Binding var isShowingFigures: Bool

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
        .mapStyle(Self.hikingStyle)
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

    /// The two controls, pushed to opposite corners.
    ///
    /// Apart rather than side by side, which is what they were: two 36 pt
    /// circles six points apart are one target as far as a cold finger is
    /// concerned, and pressing *figures* when *follow* was meant takes a hiker
    /// off the map they were reading. The screen's own width is the cheapest
    /// separation available, and it costs the map nothing — the corners are
    /// where a route is least likely to be.
    private var buttons: some View {
        HStack(spacing: 0) {
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
            Spacer(minLength: 0)
            button(symbol: "list.bullet", label: "Trail figures", tint: .primary) {
                isShowingFigures = true
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
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
                // Padding *inside* the label and a shape over the result, so
                // the target grows without the circle growing with it. The
                // shape has to be said explicitly: a `Button` whose label is an
                // image takes its hit area from what was drawn, and padding
                // alone is transparent to a tap.
                .padding(Self.buttonPadding)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
