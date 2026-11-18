//
//  OfflineCountriesList.swift
//  OpenHikes
//
//  *Offline Maps*' list: what is downloaded or coming down, the areas near
//  the hiker, then every country, the few split by size opening to their
//  states or provinces, and *Extra Detail* at the foot. The same list under
//  the map, where a row shows its area on the map behind it, and in
//  Settings, beside the storage it costs.
//
//  The body reads the list, what is installed and *Extra Detail*, which
//  change a few times a visit. A download's progress is read by its row
//  alone.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesList: View {
    let countries: OfflineCountries
    /// Where the hiker is, read once as the list comes up, for *Nearby*.
    let near: CLLocationCoordinate2D?
    var selectedID: String?
    var onSelect: (OfflineCountryManifest.Country) -> Void = { _ in /* No map to show it on. */ }

    /// The split countries open in the list.
    @State private var expanded: Set<String> = []

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
                list(countries.sections(of: listed, near: near))
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

    private func list(_ sections: OfflineCountrySections) -> some View {
        ScrollViewReader { scroller in
            List {
                if !sections.held.isEmpty {
                    Section("Downloaded") { rows(sections.held) }
                }
                if !sections.nearby.isEmpty {
                    Section("Nearby") { rows(sections.nearby) }
                }
                allCountries(sections.rest)
                detailSection
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                let target = sections.scrollTarget(for: id)
                if let group = target.opening { expanded.insert(group) }
                withAnimation { scroller.scrollTo(target.rowID, anchor: .center) }
            }
        }
    }

    private func allCountries(_ rest: [OfflineCountryListing]) -> some View {
        Section {
            ForEach(rest) { listing in
                switch listing {
                case let .area(country):
                    row(country, namesCountry: false)
                case let .group(id, regions):
                    group(id, regions)
                }
            }
        } header: {
            Text("All Countries")
        } footer: {
            Text("The OpenHikes map draws a downloaded country with no signal. Downloads use Wi-Fi.")
        }
    }

    private var detailSection: some View {
        Section {
            Toggle("Extra Detail", isOn: Binding(
                get: { countries.includesDetail },
                set: { countries.setIncludesDetail($0) }
            ))
            .accessibilityIdentifier("offline-maps-extra-detail")
        } footer: {
            Text(
                """
                Adds buildings and small places such as water taps, toilets and benches. \
                Downloads take about twice the space.
                """
            )
        }
    }

    private func group(_ id: String, _ regions: [OfflineCountryManifest.Country]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )) {
            ForEach(regions) { region in
                row(region, namesCountry: false, rowID: OfflineCountrySections.groupRowID(region.id))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(OfflineCountries.name(ofCountry: id))
                Text("\(regions.count) regions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("offline-country-group-\(id)")
    }

    private func rows(_ list: [OfflineCountryManifest.Country]) -> some View {
        ForEach(list) { country in
            row(country, namesCountry: true)
        }
    }

    private func row(_ country: OfflineCountryManifest.Country, namesCountry: Bool, rowID: String? = nil) -> some View {
        OfflineCountryRow(
            country: country,
            countries: countries,
            namesCountry: namesCountry,
            isSelected: selectedID == country.id
        ) {
            onSelect(country)
        }
        .id(rowID ?? country.id)
    }
}
