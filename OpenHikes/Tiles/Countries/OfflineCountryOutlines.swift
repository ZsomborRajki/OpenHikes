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

extension OfflineCountryManifest.Bounds {
    /// Room round a country, so its outline is inside the frame.
    static let framePadding = 1.2

    /// The region a country's row shows on the map: the whole of it, with a
    /// margin.
    var framingRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (east + west) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: (north - south) * Self.framePadding,
                longitudeDelta: (east - west) * Self.framePadding
            )
        )
    }
}
