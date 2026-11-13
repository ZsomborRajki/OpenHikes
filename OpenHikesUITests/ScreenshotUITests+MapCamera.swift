//
//  ScreenshotUITests+MapCamera.swift
//  OpenHikesUITests
//
//  What the map says of its own camera, for the frames that have to know
//  where a gesture left it: how far the tilted frame is tilted, and how much
//  ground the nearby frame's map shows.
//
//  MapKit describes its camera in the map element's accessibility value, as
//  JSON, to anything that drives it: the pitch, the zoom and the region the
//  view covers. It is the only place any of them can be read from out of
//  process. A photo pin or a red stroke can be measured on the screen; a pitch
//  cannot, and neither can a scale on a map with no two points of known
//  distance on it.
//

import XCTest

/// The part of MapKit's description of a map that the frames read.
private struct MapCameraDescription: Decodable {
    struct Camera: Decodable {
        /// Degrees from straight down.
        let pitch: Double
    }

    /// The ground the whole view covers, under the sheet or the panel too.
    struct Region: Decodable {
        let latSpan: Double
        let lonSpan: Double
        let north: Double
        let south: Double
    }

    let camera: Camera
    let fullRegion: Region
}

extension ScreenshotUITests {
    /// One degree of latitude on the ground.
    private static let kilometersPerDegree = 111.32

    /// The map's tilt in degrees, or zero where it says nothing of one.
    @MainActor
    func mapPitch(in app: XCUIApplication) -> Double {
        settledMapCamera(in: app)?.camera.pitch ?? 0
    }

    /// The ground the open map shows, in square kilometres, or `nil` where
    /// the map does not say what it covers.
    ///
    /// The open map's share of the region the whole view covers, since the
    /// view runs on under the sheet or the panel — see ``openMapArea(in:)``.
    @MainActor
    func openMapGround(in app: XCUIApplication) -> Double? {
        guard let region = settledMapCamera(in: app)?.fullRegion else { return nil }
        let map = mapElement(in: app).frame
        let open = openMapArea(in: app)
        guard map.width > 0, map.height > 0 else { return nil }
        let latitude = (region.north + region.south) / 2 * .pi / 180
        let height = region.latSpan * Self.kilometersPerDegree * Double(open.height / map.height)
        let width = region.lonSpan * Self.kilometersPerDegree * cos(latitude) * Double(open.width / map.width)
        return width * height
    }

    /// The camera once it has stopped moving: the same description twice
    /// running. A zoom and a tilt both ease to rest after the fingers lift,
    /// and a reading taken on the way is not where the map ends up.
    @MainActor
    private func settledMapCamera(in app: XCUIApplication) -> MapCameraDescription? {
        let map = mapElement(in: app)
        var last: String?
        var description: String?
        _ = waitUntil(timeout: UITestTimeout.navigation) {
            description = map.value as? String
            defer { last = description }
            return description != nil && description == last
        }
        guard let description else { return nil }
        return try? JSONDecoder().decode(MapCameraDescription.self, from: Data(description.utf8))
    }
}
