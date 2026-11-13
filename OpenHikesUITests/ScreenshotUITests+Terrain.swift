//
//  ScreenshotUITests+Terrain.swift
//  OpenHikesUITests
//
//  App Store frame 06, the walk on a tilted map with the mountains risen under
//  it, in a file of its own for the reason frames 08 and 09 have one:
//  `ScreenshotUITests.swift` is at the length the linter allows, and an
//  extension keeps it inside the one suite `Scripts/screenshots.sh` runs.
//

import XCTest

extension ScreenshotUITests {
    /// How far from straight down the map is tilted, in degrees: far enough
    /// for the Watzmann to stand up off the page, and short of where the
    /// horizon comes into the top of a wide display. It is also as far as
    /// MapKit tilts a map at the scale that shows the whole walk on the 6.9"
    /// phone.
    private static let wantedPitch = 35.0
    /// Close enough to that to leave alone. MapKit reports whole degrees.
    private static let pitchTolerance = 1.0
    /// How much of the tilt is given back at a time while the map's far edge
    /// shows — see ``tiltMap(in:)``.
    private static let pitchStep = 4.0
    /// The least tilt, in degrees, that reads as relief rather than as a map
    /// seen from a little off straight down. Where MapKit stops a tilt short
    /// of ``wantedPitch``, as it does further out, the frame is still worth
    /// shooting above this, and fails below it.
    private static let minimumPitch = 25.0
    /// What MapKit makes of two fingers drawn up the map, in degrees a point:
    /// 35° for 401 points, measured on the open iPhone Duo. Only where the
    /// first drag starts from; the ones after it go by what the one before
    /// them did.
    private static let pitchPerPoint = 0.087
    /// The most of the open map's height one tilting drag covers, and how far
    /// in from its edge the drag starts, so it begins and ends on the map.
    private static let tiltReach: CGFloat = 0.6
    private static let tiltMargin: CGFloat = 0.2
    /// Where in the open map the pan after the tilt takes hold of it, as
    /// shares of its width and height: its far corner, clear of the pins, the
    /// weather badge across from it and the buttons under it.
    private static let recenterAnchorX: CGFloat = 0.85
    private static let recenterAnchorY: CGFloat = 0.3
    /// The least the pins have to be off the middle, in points, for a pan to
    /// be worth a gesture.
    private static let recenterSlack: CGFloat = 12

    /// How many passes the tilt gets: a drag each, or a look at the map's
    /// far edge. A display as short as the iPhone Duo's cover needs more than
    /// one drag to reach the pitch, and one as tall as an iPad's held upright
    /// gives some of it back.
    private static let tiltPasses = 10

    /// The walk on Thunderforest Outdoors, tilted: the Watzmann's flank and
    /// the lake's trench risen under the tiles, the line and the photographs.
    ///
    /// Every other frame looks straight down. This is the one that shows the
    /// map can be tilted, and that a raster map lies over the terrain when it
    /// is — see `MapCoordinator+TerrainUnderTiles.swift` — with the *2D*
    /// button that lays it flat again standing over the location button. It
    /// took the place of the hero's composition on Stadia Outdoors, which
    /// said only that a map can be chosen.
    ///
    /// Thunderforest Outdoors has to be selected first: `--ui-test-entitled`
    /// grants the Pro entitlement and selects nothing. Its contours are what
    /// the relief reads by once it is tilted.
    @MainActor
    func testCapturesTheTrailInThreeDimensions() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-entitled",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        selectMap("thunderforest_outdoors", in: app)
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app, selecting: Self.pinnedPhotoIndexes)
        showWholeRouteOnTheMap(in: app)
        tiltMap(in: app)
        recenterPhotoPins(in: app)

        // The farthest photograph from the eye, which on a map tilted away
        // from it is the topmost: its callout stands over the far end of the
        // walk, and the climb the frame is of stays clear in front of it.
        let farthest = try XCTUnwrap(photoPins(in: app).first, "the map should be showing photo pins")
        farthest.tap()
        XCTAssertTrue(
            element("photo-pin-preview", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "selecting a photo pin should open a callout previewing the photo"
        )
        capture(as: .terrain, of: app)
    }

    /// Picks one of the catalog's maps in Settings, by its provider id.
    ///
    /// A paid one is only listed for an entitled launch with its key bundled,
    /// which is what the failure says.
    @MainActor
    func selectMap(_ providerID: String, in app: XCUIApplication) {
        element("settings-button", in: app).tap()
        let provider = element("provider-row-\(providerID)", in: app)
        XCTAssertTrue(
            provider.waitForExistence(timeout: UITestTimeout.navigation),
            "Settings should offer \(providerID) — a paid map needs --ui-test-entitled and its key in "
                + "OpenHikes/Secrets.plist"
        )
        provider.tap()
        app.buttons["settings-close"].tap()
    }

    /// Draws the photo pins back to the middle of the open map, which the
    /// tilt took them from.
    ///
    /// A map tilts about its middle, and the near end of the walk swings
    /// down the screen as it does: on an iPad held upright, where the route
    /// was fitted to the map's full height, off the bottom of it.
    @MainActor
    private func recenterPhotoPins(in app: XCUIApplication) {
        let area = openMapArea(in: app)
        guard let pins = Self.bounds(of: photoPins(in: app)) else { return }
        let offset = CGVector(dx: area.midX - pins.midX, dy: area.midY - pins.midY)
        guard hypot(offset.dx, offset.dy) > Self.recenterSlack else { return }
        let anchor = CGPoint(
            x: area.minX + area.width * Self.recenterAnchorX,
            y: area.minY + area.height * Self.recenterAnchorY
        )
        panMap(mapElement(in: app), from: anchor, to: CGPoint(x: anchor.x + offset.dx, y: anchor.y + offset.dy))
    }

    /// Tilts the map to ``wantedPitch`` with two fingers drawn up the open
    /// part of it, which MapKit reads as a tilt away from straight down.
    ///
    /// Measured rather than assumed, as the hero's pans are. A drag tilts a
    /// map by the points it covers, the displays this set is shot on differ
    /// by a factor of two in how many they have, and MapKit stops a tilt at a
    /// pitch that depends on how far out the camera is. So each drag is sized
    /// by what is still missing, at the rate the drag before it turned out to
    /// have, until the camera says it is there or will go no further.
    ///
    /// **And no further than the ground goes.** MapKit draws a tilted map
    /// out to a distance and flat grey past it, and a display as tall as an
    /// iPad's held upright sees that far at 35°: a grey band 70 points deep
    /// under its status bar. So once the pitch is reached the top of the map
    /// is looked at, and while the band is there the tilt gives a little back.
    ///
    /// The *2D* button is what says the app took the tilt for one: it is up
    /// exactly while the terrain is under the tiles.
    @MainActor
    private func tiltMap(in app: XCUIApplication) {
        let area = openMapArea(in: app)
        let display = screenshotDisplay(in: app)
        let reach = Double(area.height * Self.tiltReach)
        var wanted = Self.wantedPitch
        var rate = Self.pitchPerPoint
        var pitch = mapPitch(in: app)
        for _ in 0..<Self.tiltPasses {
            let missing = wanted - pitch
            guard abs(missing) > Self.pitchTolerance else {
                guard screenshotMapShowsItsFarEdge(in: app, on: display) else { break }
                wanted -= Self.pitchStep
                continue
            }
            let travel = min(max(missing / rate, -reach), reach)
            // Up the map from its lower part to tilt further, and down it
            // from its upper part to come back.
            let start = area.minY + area.height * (travel > 0 ? 1 - Self.tiltMargin : Self.tiltMargin)
            XCTAssertTrue(
                ScreenshotDisplayGesture.dragWithTwoFingers(
                    from: CGPoint(x: area.midX, y: start),
                    to: CGPoint(x: area.midX, y: start - CGFloat(travel)),
                    on: display
                )
            )
            let reached = mapPitch(in: app)
            // A drag that gained nothing found MapKit's own limit for this
            // scale, and says nothing about the rate.
            guard reached != pitch else { break }
            rate = (reached - pitch) / travel
            pitch = reached
        }
        XCTAssertTrue(
            (Self.minimumPitch...Self.wantedPitch + Self.pitchTolerance).contains(pitch),
            "two fingers drawn up the map should tilt it to about \(Self.wantedPitch)°, not \(pitch)°"
        )
        XCTAssertFalse(
            screenshotMapShowsItsFarEdge(in: app, on: display),
            "and the tilt should stop short of the map's far edge"
        )
        XCTAssertTrue(
            element("map-flatten-button", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a tilted map offers 2D"
        )
    }
}
