//
//  OfflineCountryOutlines.swift
//  OpenHikes
//
//  The countries *Offline Maps* lists, outlined on the map behind it, the
//  downloaded ones filled, so a hiker sees what a download covers before
//  starting it: whether the bit of a trail over the border is in it. A tap
//  inside an outline chooses that country's row.
//
//  Held by ``OfflineCountries`` and observed directly by the map (not via
//  SwiftUI), as the other screens' pins are, so the list choosing a country
//  restyles MapKit's overlays and re-runs no view. See
//  `MapCoordinator+CountryOutlines.swift`.
//

import CoreLocation
import MapKit
import Observation
import OpenHikesData

@MainActor
@Observable
final class OfflineCountryOutlines {
    /// Whether the screen is up and the outlines are drawn.
    private(set) var isActive = false
    private(set) var countries: [OfflineCountryManifest.Country] = []
    private(set) var installedIDs: Set<String> = []
    private(set) var selectedID: String?

    @ObservationIgnored private var activeToken: Int?
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var onSelect: ((String) -> Void)?

    nonisolated deinit { /* intentionally empty */ }

    /// Takes the map for the screen. The newest screen to attach holds it.
    @discardableResult func attach(onSelect: @escaping (String) -> Void) -> Int {
        nextToken += 1
        activeToken = nextToken
        self.onSelect = onSelect
        if !isActive { isActive = true }
        return nextToken
    }

    func show(
        _ countries: [OfflineCountryManifest.Country],
        installed: Set<String>,
        selected: String?,
        token: Int
    ) {
        guard activeToken == token else { return }
        if countries != self.countries { self.countries = countries }
        if installed != installedIDs { installedIDs = installed }
        if selected != selectedID { selectedID = selected }
    }

    func detach(token: Int) {
        guard activeToken == token else { return }
        activeToken = nil
        onSelect = nil
        if !countries.isEmpty { countries = [] }
        if selectedID != nil { selectedID = nil }
        if isActive { isActive = false }
    }

    /// A tap on the map: chooses the country under it, if the screen is up
    /// and there is one. Answers whether the tap was taken.
    @discardableResult func select(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard isActive, let onSelect,
              let country = countries.first(where: { country in
                  country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude)
              })
        else { return false }
        onSelect(country.id)
        return true
    }
}

extension OfflineCountryManifest.Country {
    /// Room round an area, so its outline is inside the frame.
    static let framePadding = 1.2

    /// The region an area's row shows on the map: the whole of its outline,
    /// with a margin.
    ///
    /// Measured round the outline the short way (``TileBoundingBox``), not
    /// across the bounds. An area across the antimeridian, such as Fiji,
    /// Chukotka or Alaska, is listed with bounds round the whole globe, whose
    /// middle is the far side of the world from it. Its region runs on past
    /// ±180° instead, and ``MKCoordinateRegion/mapRect`` carries that to
    /// MapKit. An area listed without an outline is framed by its bounds.
    var framingRegion: MKCoordinateRegion {
        let vertices = outline.joined().compactMap { vertex in
            vertex.count >= 2 ? CLLocationCoordinate2D(latitude: vertex[1], longitude: vertex[0]) : nil
        }
        guard let box = TileBoundingBox(route: vertices) else {
            return Self.framing(
                south: bounds.south, north: bounds.north, west: bounds.west, width: bounds.east - bounds.west
            )
        }
        return Self.framing(south: box.southLat, north: box.northLat, west: box.westLon, width: box.lonSpan)
    }

    /// A region round a box `width` degrees east of `west`, with the margin.
    private static func framing(south: Double, north: Double, west: Double, width: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (north + south) / 2,
                longitude: RouteGeometry.normalizedLongitude(west + width / 2)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: (north - south) * framePadding,
                longitudeDelta: min(width * framePadding, 360)
            )
        )
    }
}
