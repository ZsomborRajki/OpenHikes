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
    /// for the Watzmann to stand up off the page. It is also as far as MapKit
    /// tilts a map at the scale that shows the whole walk on the 6.9" phone.
    private static let wantedPitch = 35.0
    /// How far past that a tilt may land. MapKit reports whole degrees.
    private static let pitchTolerance = 1.0
    /// The least tilt, in degrees, that reads as relief rather than as a map
    /// seen from a little off straight down. Where a drag stops short of
    /// ``wantedPitch``, the frame is still worth shooting above this, and
    /// fails below it.
    private static let minimumPitch = 25.0
    /// What MapKit makes of two fingers drawn up the map, in degrees a point:
    /// 35° for 401 points, measured on the open iPhone Duo. Only where the
    /// first drag starts from; the ones after it go by what the one before
    /// them did.
    private static let pitchPerPoint = 0.087
    /// The most of the open map's height one tilting drag covers, and how far
    /// up from its bottom edge the drag starts, so it begins and ends on the
    /// map.
    private static let tiltReach: CGFloat = 0.6
    private static let tiltMargin: CGFloat = 0.2
    /// How many drags a tilt gets. A display as short as the iPhone Duo's
    /// cover needs more than one to reach the pitch.
    private static let tiltPasses = 3
    /// The shortest drag worth making, in points. MapKit does not read a
    /// short one as a tilt: 28 points up from 25° laid the open iPhone Duo's
    /// map flat.
    private static let leastTiltTravel = 100.0

    /// Where in the open map a pan of the tilted map takes hold of it, as
    /// shares of its width and height: its far corner, clear of the pins, the
    /// callout, the weather badge across from it and the buttons under it.
    private static let panAnchorX: CGFloat = 0.85
    private static let panAnchorY: CGFloat = 0.3
    /// The least the pins have to be off the middle, in points, for a pan to
    /// be worth a gesture.
    private static let recenterSlack: CGFloat = 12
    /// How much further than the far edge is deep the map is drawn back from
    /// it, in points, and how many times it is.
    private static let farEdgeMargin: CGFloat = 16
    private static let farEdgePasses = 4

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
        let callout = element("photo-pin-preview", in: app)
        XCTAssertTrue(
            callout.waitForExistence(timeout: UITestTimeout.existence),
            "selecting a photo pin should open a callout previewing the photo"
        )
        drawMapBackFromItsFarEdge(in: app)
        XCTAssertGreaterThanOrEqual(
            callout.frame.minY,
            openMapArea(in: app).minY,
            "the callout should still be whole once the map has been drawn back"
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
    /// Long drags up only: what is missing by less than
    /// ``leastTiltTravel`` is left missing.
    ///
    /// The *2D* button is what says the app took the tilt for one: it is up
    /// exactly while the terrain is under the tiles.
    @MainActor
    private func tiltMap(in app: XCUIApplication) {
        let area = openMapArea(in: app)
        let display = screenshotDisplay(in: app)
        let reach = Double(area.height * Self.tiltReach)
        let start = CGPoint(x: area.midX, y: area.minY + area.height * (1 - Self.tiltMargin))
        var rate = Self.pitchPerPoint
        var pitch = mapPitch(in: app)
        for _ in 0..<Self.tiltPasses {
            let travel = min((Self.wantedPitch - pitch) / rate, reach)
            guard travel >= Self.leastTiltTravel else { break }
            XCTAssertTrue(
                ScreenshotDisplayGesture.dragWithTwoFingers(
                    from: start, to: CGPoint(x: start.x, y: start.y - CGFloat(travel)), on: display
                )
            )
            let reached = mapPitch(in: app)
            // A drag that gained nothing found MapKit's own limit for this
            // scale, and says nothing about the rate.
            guard reached > pitch else { break }
            rate = (reached - pitch) / travel
            pitch = reached
        }
        XCTAssertTrue(
            (Self.minimumPitch...Self.wantedPitch + Self.pitchTolerance).contains(pitch),
            "two fingers drawn up the map should tilt it to about \(Self.wantedPitch)°, not \(pitch)°"
        )
        XCTAssertTrue(
            element("map-flatten-button", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a tilted map offers 2D"
        )
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
        let anchor = tiltedPanAnchor(in: area)
        panMap(mapElement(in: app), from: anchor, to: CGPoint(x: anchor.x + offset.dx, y: anchor.y + offset.dy))
    }

    /// Draws the map up the screen while its far edge shows along the top of
    /// it, and leaves the map settled.
    ///
    /// MapKit draws a tilted map's ground out to a distance, and flat grey
    /// past it. That edge moves with the ground, so whatever draws the map
    /// down the screen after the tilt can bring it into the picture: on the
    /// open iPhone Duo on its side, the room MapKit makes above a pin for its
    /// callout put a band fifteen points deep along the top. Measured there,
    /// the band was absent after the tilt and after the pins were recentred,
    /// there once the callout was open, and gone again after a pan back up.
    ///
    /// So this is the frame's last move, and it reads the band's depth off
    /// the settled picture and pans by that much. The grey is only drawn once
    /// the ground short of it is, so each look waits for the map first, which
    /// is also the wait ``capture(as:of:)`` would otherwise make.
    @MainActor
    private func drawMapBackFromItsFarEdge(in app: XCUIApplication) {
        let display = screenshotDisplay(in: app)
        let anchor = tiltedPanAnchor(in: openMapArea(in: app))
        for _ in 0..<Self.farEdgePasses {
            settleScreenshotMapTiles(in: app)
            let depth = screenshotMapFarEdgeDepth(in: app, on: display)
            guard depth > 0 else { return }
            let landing = CGPoint(x: anchor.x, y: anchor.y - depth - Self.farEdgeMargin)
            panMap(mapElement(in: app), from: anchor, to: landing)
        }
        settleScreenshotMapTiles(in: app)
        XCTAssertEqual(
            screenshotMapFarEdgeDepth(in: app, on: display),
            0,
            "the map should have been drawn back from its far edge"
        )
    }

    @MainActor
    private func tiltedPanAnchor(in area: CGRect) -> CGPoint {
        CGPoint(x: area.minX + area.width * Self.panAnchorX, y: area.minY + area.height * Self.panAnchorY)
    }
}
