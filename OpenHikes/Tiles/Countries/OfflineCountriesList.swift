//
//  OfflineCountriesList.swift
//  OpenHikes
//
//  *Offline Maps*' list: a field to search the areas by name and the order
//  they are in, over the list itself, which says which map the downloads are
//  for, holds *Extra Detail*, and then lists the downloads not yet in, what
//  is downloaded, and every other area in the order chosen
//  (``OfflineCountrySort``).
//  By name the countries stand under their letters, with the letters down
//  the trailing edge to jump by, and the few split by size open to their
//  states or provinces. The same list under the map, where a row shows its
//  area on the map behind it, and in Settings, beside the storage it costs.
//
//  The body reads the list's revision, what is installed, *Extra Detail*,
//  the order and the query, which change a few times a visit or once a
//  keystroke. What it orders and finds the areas by is prepared off the main
//  actor, by a task for each revision of the list and each position, and
//  kept across those passes, the last one drawn until the next is ready
//  (``OfflineCountryDirectoryCache``). A download's progress is read by its
//  row alone. The query, the order, the countries open and that directory
//  are kept outside it (``OfflineCountriesListState``), because under the
//  map a turn of the phone builds the list again.
//

import CoreLocation
import SwiftUI

struct OfflineCountriesList: View {
    let countries: OfflineCountries
    /// The search, the order picked, the countries open and the directory.
    @Bindable var state: OfflineCountriesListState
    /// Where the hiker is, read once as the list comes up, for the order it
    /// opens in.
    let near: CLLocationCoordinate2D?
    var selectedID: String?
    /// Whether the list stands over the map, on the sheet's or the side
    /// panel's glass, rather than on Settings' own ground.
    var isOverMap = false
    /// Whether the list stands at its full height, which a sheet at its
    /// middle does not: the search field gives the keyboard up there, and
    /// the index, which needs the height, is put away.
    var hasFullHeight = true
    /// The search field took the keyboard.
    var onSearch: () -> Void = { /* No sheet to raise. */ }
    var onSelect: (OfflineCountryManifest.Country) -> Void = { _ in /* No map to show it on. */ }

    /// The area the list owes a scroll to, chosen by a row or on the map,
    /// until a list that holds its row has gone to it.
    @State private var revealing: String?
    @FocusState private var isSearchFocused: Bool

    private var directories: OfflineCountryDirectoryCache { state.directories }

    var body: some View {
        if !countries.isAvailable {
            ContentUnavailableView(
                "Offline Maps Aren’t Available",
                systemImage: "map",
                description: Text("This build can’t download countries.")
            )
        } else {
            let key = OfflineCountryDirectoryCache.Key(catalog: countries.catalogRevision, near: near)
            prepared
                .task(id: key) {
                    // The list as the model holds it now, outside the body,
                    // and put on screen only while the model holds it still.
                    let source = OfflineCountryDirectory.Source(
                        offered: countries.offered,
                        installed: countries.installed,
                        near: near
                    )
                    await directories.prepare(key, from: source) { countries.catalogRevision == key.catalog }
                }
                // Here rather than on the list, which is not drawn until the
                // first directory is prepared: the map outlines the list off
                // the server, and an area chosen there before then is owed a
                // scroll all the same.
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    revealing = id
                    state.clearSearch(hiding: id)
                }
        }
    }

    /// The list, once a directory is prepared and has areas in it.
    @ViewBuilder private var prepared: some View {
        if let directory = directories.directory, !directory.isEmpty {
            content(directory)
        } else {
            emptyState(isPrepared: directories.directory != nil)
        }
    }

    /// - Parameter isPrepared: Whether a directory is prepared: until one
    ///   is, the list is still coming, whatever the server answered.
    @ViewBuilder
    private func emptyState(isPrepared: Bool) -> some View {
        if isPrepared, countries.listPhase == .failed {
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
                chosenSort: state.chosenSort,
                orders: OfflineCountrySort.offered(hasPosition: directory.hasPosition)
            ) { state.choose($0, over: sort) }
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
    }

    /// What the list goes to an area again on: the area it owes a scroll to,
    /// and the directory it draws. One change, so that a directory drawn as
    /// an area is chosen asks once, and a country opened is not scrolled
    /// into before its regions are in the list.
    private struct OwedScroll: Equatable {
        let id: String?
        let directory: OfflineCountryDirectoryCache.Key?
    }

    // MARK: - The list

    private func list(_ sections: OfflineCountrySections, by sort: OfflineCountrySort) -> some View {
        ScrollViewReader { scroller in
            List {
                Group {
                    OfflineCountriesHead(countries: countries)
                    // Apart, because only the second draws with no signal.
                    if !sections.unfinished.isEmpty {
                        Section("Not Yet Downloaded") { rows(sections.unfinished) }
                    }
                    if !sections.downloaded.isEmpty {
                        Section("Downloaded") { rows(sections.downloaded) }
                    }
                    ForEach(sections.parts) { part in
                        section(part, isLast: part.id == sections.parts.last?.id)
                    }
                }
                // Over the map, the cards the hike detail's are. A sheet draws
                // a grouped list's own cards on its glass without asking, but
                // on ``MapSidePanel``, which is no presentation, every one was
                // opaque, *Extra Detail* included: white beside the map, or
                // near black in dark. An area's row sets its own, for its
                // tint when chosen — see ``OfflineCountryRow``.
                .placeCardRows(isOverMap)
            }
            // A list of its own an order, so another order starts at its head
            // rather than as far down as the last one was scrolled.
            .id(sort)
            // What the side panel stands as tall as — see ``SidePanelFit``.
            .fitsSidePanel()
            .scrollDismissesKeyboard(.immediately)
            // As the list comes up too: a search gives way to it with the
            // area it owes a scroll to already chosen. And as a newer
            // directory is drawn, which may be the first to hold it.
            .onChange(of: OwedScroll(id: revealing, directory: directories.shown), initial: true) {
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
        case .wait:
            // Still owed, until a directory that holds it is drawn.
            break
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
            isSelected: selectedID == country.id,
            isOverMap: isOverMap
        ) {
            // The keyboard would stand over the map the row is shown on.
            isSearchFocused = false
            onSelect(country)
        }
        .id(rowID ?? country.id)
    }
}
