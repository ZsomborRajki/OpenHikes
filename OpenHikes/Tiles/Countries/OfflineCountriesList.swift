//
//  OfflineCountriesList.swift
//  OpenHikes
//
//  *Offline Maps*' list: what is downloaded or coming down, the countries
//  near the hiker, then every other country. The same list under the map, where a
//  row shows its country on the map behind it, and in Settings, beside the
//  storage it costs.
//
//  The body reads the list and what is installed, which change a few times a
//  visit. A download's progress is read by its row alone.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesList: View {
    let countries: OfflineCountries
    /// Where the hiker is, read once as the list comes up, for *Nearby*.
    let near: CLLocationCoordinate2D?
    var selectedID: String?
    var onSelect: (OfflineCountryManifest.Country) -> Void = { _ in /* No map to show it on. */ }

    var body: some View {
        if !countries.isAvailable {
            ContentUnavailableView(
                "Offline Maps Aren’t Available",
                systemImage: "map",
                description: Text("This build can’t download countries.")
            )
        } else {
            let listed = countries.listed
            if listed.isEmpty {
                emptyState
            } else {
                list(listed)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if countries.listPhase == .failed {
            ContentUnavailableView {
                Label("Couldn’t Load Countries", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") {
                    Task { await countries.refreshList() }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading countries")
        }
    }

    private func list(_ listed: [OfflineCountryManifest.Country]) -> some View {
        let sections = countries.sections(of: listed, near: near)
        return ScrollViewReader { scroller in
            List {
                if !sections.held.isEmpty {
                    Section("Downloaded") { rows(sections.held) }
                }
                if !sections.nearby.isEmpty {
                    Section("Nearby") { rows(sections.nearby) }
                }
                Section {
                    rows(sections.rest)
                } header: {
                    Text("All Countries")
                } footer: {
                    Text("The OpenHikes map draws a downloaded country with no signal. Downloads use Wi-Fi.")
                }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation { scroller.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func rows(_ list: [OfflineCountryManifest.Country]) -> some View {
        ForEach(list) { country in
            OfflineCountryRow(
                country: country,
                countries: countries,
                isSelected: selectedID == country.id
            ) {
                onSelect(country)
            }
            .id(country.id)
        }
    }
}
