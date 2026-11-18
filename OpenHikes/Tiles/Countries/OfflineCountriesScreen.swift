//
//  OfflineCountriesScreen.swift
//  OpenHikes
//
//  *Offline Maps*, pushed into the map sheet from *Map Modes*: the list of
//  countries over the map, with every country outlined behind it and the
//  downloaded ones filled. A row shows its country on the map; a tap inside
//  an outline chooses its row. The map is the point of putting the list here
//  rather than in Settings alone: whether the stretch of a trail over a
//  border is in a download is a question the map answers at a glance.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesScreen: View {
    let countries: OfflineCountries
    let locationManager: LocationManager
    let mapController: MapController
    /// Brings the sheet down to its middle, so the map is in view.
    let onShowMap: () -> Void

    @State private var token: Int?
    @State private var selectedID: String?
    @State private var near: CLLocationCoordinate2D?

    var body: some View {
        OfflineCountriesList(countries: countries, near: near, selectedID: selectedID) { country in
            select(country.id, framing: true)
        }
        .scrollContentBackground(.hidden)
        // What the side panel stands as tall as — see ``SidePanelFit``.
        .fitsSidePanel()
        .navigationTitle("Offline Maps")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
        .onChange(of: OutlineInputs(countries: countries.listed, installed: Set(countries.installed.keys))) {
            showOutlines()
        }
        .task { await countries.refreshList() }
    }

    /// What the outlines are drawn from: the list and what is downloaded.
    private struct OutlineInputs: Equatable {
        let countries: [OfflineCountryManifest.Country]
        let installed: Set<String>
    }

    private func attach() {
        // Once, as the list comes up: the hiker's position moving under an
        // open list must not reorder it.
        near = locationManager.coordinate
        token = countries.outlines.attach { id in select(id, framing: false) }
        showOutlines()
    }

    /// Gives the map back, unless another screen has claimed it since.
    private func detach() {
        guard let token else { return }
        self.token = nil
        countries.outlines.detach(token: token)
    }

    private func showOutlines() {
        guard let token else { return }
        countries.outlines.show(
            countries.listed,
            installed: Set(countries.installed.keys),
            selected: selectedID,
            token: token
        )
    }

    /// Chooses a country's row, and with `framing`, which a row's tap asks
    /// for and a tap on the map does not, moves the map to the whole of it.
    private func select(_ id: String, framing: Bool) {
        selectedID = id
        showOutlines()
        guard framing, let country = countries.listed.first(where: { $0.id == id }) else { return }
        onShowMap()
        mapController.show(country.bounds.framingRegion)
    }
}
