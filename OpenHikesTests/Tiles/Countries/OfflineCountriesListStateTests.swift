//
//  OfflineCountriesListStateTests.swift
//  OpenHikesTests
//
//  What *Offline Maps*' list holds while it is up, beyond the order picked
//  (`OfflineCountryDirectoryTests`): a search gives way to an area chosen on
//  the map that it would hide, and only to one it would hide, as far as the
//  directory the list draws can say.
//

import Foundation
@testable import OpenHikes
import Testing

// swiftlint:disable no_magic_numbers

@MainActor
@Suite("Offline countries: what the list holds while it is up")
struct OfflineCountriesListStateTests {
    private let slovenia = OfflineCountryFixture.country(bytes: Data(count: 10))
    private let austria = OfflineCountryFixture.northernCountry(bytes: Data(count: 30))

    /// A list state drawing the directory of Austria and Slovenia.
    private func drawingTwoCountries() async -> OfflineCountriesListState {
        let state = OfflineCountriesListState()
        await state.directories.prepare(
            OfflineCountryDirectoryCache.Key(catalog: 1, near: nil),
            from: OfflineCountryDirectory.Source(offered: [austria, slovenia], installed: [:], near: nil)
        ) { true }
        return state
    }

    @Test("a search that holds the area chosen on the map is kept, and one that would hide it is cleared")
    func searchGivesWayToWhatItHides() async {
        let state = await drawingTwoCountries()

        state.query = "Slov"
        state.clearSearch(hiding: "SI")
        #expect(state.query == "Slov")

        state.clearSearch(hiding: "AT")
        #expect(state.query.isEmpty)
    }

    /// The map outlines the list off the server, so an area can be chosen
    /// there before the list has a directory to search.
    @Test("with no directory yet a search is cleared, since whether it holds the area is not known")
    func searchClearedBeforeADirectory() {
        let state = OfflineCountriesListState()

        state.query = "Slov"
        state.clearSearch(hiding: "SI")
        #expect(state.query.isEmpty)
    }

    @Test("a field holding only spaces is no search, and is left as typed")
    func spacesAreNoSearch() async {
        let state = await drawingTwoCountries()

        state.query = "  "
        state.clearSearch(hiding: "AT")
        #expect(state.query == "  ")
    }
}

// swiftlint:enable no_magic_numbers
