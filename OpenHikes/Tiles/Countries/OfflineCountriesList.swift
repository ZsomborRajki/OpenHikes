//
//  OfflineCountriesList.swift
//  OpenHikes
//
//  *Offline Maps*' list: a field to search the areas by name and the order
//  they are in, over the list itself, which says which map the downloads are
//  for, holds *Extra Detail*, and then lists what is downloaded or coming
//  down and every other area in the order chosen (``OfflineCountrySort``).
//  By name the countries stand under their letters, with the letters down
//  the trailing edge to jump by, and the few split by size open to their
//  states or provinces. The same list under the map, where a row shows its
//  area on the map behind it, and in Settings, beside the storage it costs.
//
//  The body reads the list, what is installed, *Extra Detail*, the order
//  and the query, which change a few times a visit or once a keystroke. What
//  it orders and finds the areas by is kept across those passes
//  (``OfflineCountryDirectoryCache``). A download's progress is read by its
//  row alone. The query, the order and the countries open are kept outside
//  it (``OfflineCountriesListState``), because under the map a turn of the
//  phone builds the list again.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesList: View {
    let countries: OfflineCountries
    /// The search, the order picked and the countries open.
    @Bindable var state: OfflineCountriesListState
    /// Where the hiker is, read once as the list comes up, for the order it
    /// opens in.
    let near: CLLocationCoordinate2D?
    var selectedID: String?
    /// Whether the list stands at its full height, which a sheet at its
    /// middle does not: the search field gives the keyboard up there, and
    /// the index, which needs the height, is put away.
    var hasFullHeight = true
    /// The search field took the keyboard.
    var onSearch: () -> Void = { /* No sheet to raise. */ }
    var onSelect: (OfflineCountryManifest.Country) -> Void = { _ in /* No map to show it on. */ }

    @State private var directories = OfflineCountryDirectoryCache()
    /// The area the list owes a scroll to, chosen by a row or on the map,
    /// until a list that holds its row has gone to it.
    @State private var revealing: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        if !countries.isAvailable {
            ContentUnavailableView(
                "Offline Maps Aren’t Available",
                systemImage: "map",
                description: Text("This build can’t download countries.")
            )
        } else {
            let directory = directories.directory(
                offered: countries.offered,
                installed: countries.installed,
                near: near
            )
            if directory.isEmpty {
                emptyState
            } else {
                content(directory)
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

    private func content(_ directory: OfflineCountryDirectory) -> some View {
        let sort = OfflineCountrySort.inForce(chosen: state.chosenSort, hasPosition: directory.hasPosition)
        let asked = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            OfflineCountriesBar(
                query: $state.query,
                isSearchFocused: $isSearchFocused,
                sort: sort,
                orders: OfflineCountrySort.offered(hasPosition: directory.hasPosition)
            ) { state.chosenSort = $0 }
            if asked.isEmpty {
                list(countries.sections(of: directory, by: sort), by: sort)
            } else {
                results(directory.areas(matching: asked), for: asked)
            }
        }
        .onChange(of: isSearchFocused) { _, isFocused in
            if isFocused { onSearch() }
        }
        .onChange(of: hasFullHeight) { _, hasHeight in
            if !hasHeight { isSearchFocused = false }
        }
        .onChange(of: selectedID) { _, id in
            guard let id else { return }
            revealing = id
            // An area chosen on the map is shown in the list, which a search
            // that does not hold it would hide.
            if !asked.isEmpty, !directory.areas(matching: asked).contains(where: { $0.id == id }) {
                state.query = ""
            }
        }
    }

    // MARK: - The list

    private func list(_ sections: OfflineCountrySections, by sort: OfflineCountrySort) -> some View {
        ScrollViewReader { scroller in
            List {
                OfflineCountriesHead(countries: countries)
                if !sections.held.isEmpty {
                    Section("Downloaded") { rows(sections.held) }
                }
                ForEach(sections.parts) { part in
                    section(part, isLast: part.id == sections.parts.last?.id)
                }
            }
            // A list of its own an order, so another order starts at its head
            // rather than as far down as the last one was scrolled.
            .id(sort)
            // What the side panel stands as tall as — see ``SidePanelFit``.
            .fitsSidePanel()
            .scrollDismissesKeyboard(.immediately)
            // As the list comes up too: a search gives way to it with the
            // area it owes a scroll to already chosen.
            .onChange(of: revealing, initial: true) {
                reveal(in: sections, with: scroller)
            }
            // A region's row is in the list only once its country is open.
            .onChange(of: state.expanded) {
                reveal(in: sections, with: scroller)
            }
        }
    }

    /// Goes to the area the list owes a scroll to, or first opens the
    /// country it is under (``OfflineCountrySections/reveal(_:expanded:)``).
    private func reveal(in sections: OfflineCountrySections, with scroller: ScrollViewProxy) {
        guard let id = revealing else { return }
        switch sections.reveal(id, expanded: state.expanded) {
        case let .open(group):
            state.expanded.insert(group)
        case let .scroll(rowID):
            revealing = nil
            withAnimation { scroller.scrollTo(rowID, anchor: .center) }
        }
    }

    @ViewBuilder
    private func section(_ part: OfflineCountrySections.Part, isLast: Bool) -> some View {
        let section = Section {
            ForEach(part.lines) { line in
                switch line {
                case let .area(country):
                    row(country)
                case let .group(id, regions):
                    group(id, regions)
                }
            }
        } header: {
            switch part.heading {
            case .nearby: Text("Nearby")
            case .all: Text("All Countries")
            case let .letter(letter): Text(verbatim: letter)
            }
        } footer: {
            if isLast {
                Text("The OpenHikes map draws a downloaded country with no signal. Downloads use Wi-Fi.")
            }
        }
        if case let .letter(letter) = part.heading {
            // Only at the list's full height: at a sheet's middle the
            // letters do not fit down its edge.
            section.sectionIndexLetter(letter, isShown: hasFullHeight)
        } else {
            section
        }
    }

    /// What a search found, best first, or that it found nothing.
    @ViewBuilder
    private func results(_ found: [OfflineCountryManifest.Country], for asked: String) -> some View {
        if found.isEmpty {
            ContentUnavailableView.search(text: asked)
        } else {
            ScrollViewReader { scroller in
                List {
                    rows(found)
                }
                .contentMargins(.top, 0, for: .scrollContent)
                .fitsSidePanel()
                .scrollDismissesKeyboard(.immediately)
                // An area chosen on the map that the search holds is gone to
                // here; one it does not hold has cleared the search, and the
                // list it gave way to goes to it.
                .onChange(of: revealing, initial: true) { _, id in
                    guard let id, found.contains(where: { $0.id == id }) else { return }
                    revealing = nil
                    withAnimation { scroller.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func group(_ id: String, _ regions: [OfflineCountryManifest.Country]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { state.expanded.contains(id) },
            set: { isOpen in
                if isOpen { state.expanded.insert(id) } else { state.expanded.remove(id) }
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
            // On the label, not the group: a container's identifier reaches
            // every row in it, and each region's row has its own.
            .accessibilityIdentifier("offline-country-group-\(id)")
        }
    }

    private func rows(_ list: [OfflineCountryManifest.Country]) -> some View {
        ForEach(list) { country in
            row(country)
        }
    }

    /// - Parameter namesCountry: Whether a region is named with its country,
    ///   as it is anywhere but under that country.
    private func row(
        _ country: OfflineCountryManifest.Country,
        namesCountry: Bool = true,
        rowID: String? = nil
    ) -> some View {
        OfflineCountryRow(
            country: country,
            countries: countries,
            namesCountry: namesCountry,
            isSelected: selectedID == country.id
        ) {
            // The keyboard would stand over the map the row is shown on.
            isSearchFocused = false
            onSelect(country)
        }
        .id(rowID ?? country.id)
    }
}
