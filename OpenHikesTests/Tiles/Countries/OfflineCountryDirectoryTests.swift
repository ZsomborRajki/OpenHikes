//
//  OfflineCountryDirectoryTests.swift
//  OpenHikesTests
//
//  The orders *Offline Maps* can be put in, and its search. By name every
//  country is under the letter its name is filed under; nearest first and
//  largest first are flat, a region a line of its own; the downloads not yet
//  finished and then what is downloaded are first in each. A search lists what answers it best first,
//  a region answering to its country's name too. And the directory all of it
//  is read from is built when the list or the hiker's position changes, not
//  at every pass.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

// swiftlint:disable no_magic_numbers

@MainActor
@Suite("Offline countries: the list's orders")
struct OfflineCountryDirectoryTests {
    private typealias Country = OfflineCountryManifest.Country
    private typealias Part = OfflineCountrySections.Part

    /// An area as big as `bytes`, filling `bounds`: a region where its code
    /// is one, named in English.
    private static func area(
        _ id: String,
        bytes: Int,
        west: Double,
        south: Double,
        east: Double,
        north: Double,
        name: String? = nil
    ) -> Country {
        var area = OfflineCountryFixture.country(
            bytes: Data(count: bytes),
            id: id,
            group: name == nil ? nil : String(id.prefix(2)),
            names: name.map { ["en": $0] } ?? [:]
        )
        area.bounds = OfflineCountryManifest.Bounds(west: west, south: south, east: east, north: north)
        area.outline = OfflineCountryFixture.outline(of: area.bounds)
        return area
    }

    private let aland = area("AX", bytes: 30, west: 19.3, south: 59.9, east: 21.1, north: 60.5)
    private let austria = area("AT", bytes: 30, west: 9.5, south: 46.9, east: 17.2, north: 49.0)
    private let slovenia = area("SI", bytes: 10, west: 13.3, south: 45.4, east: 16.6, north: 46.9)
    private let spain = area("ES", bytes: 40, west: -9.3, south: 36.0, east: 3.3, north: 43.8)
    private let california = area(
        "US-CA", bytes: 50, west: -124.4, south: 32.5, east: -114.1, north: 42.0, name: "California"
    )
    private let colorado = area(
        "US-CO", bytes: 20, west: -109.0, south: 37.0, east: -102.0, north: 41.0, name: "Colorado"
    )
    private let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)

    private var everything: [Country] { [spain, colorado, austria, california, slovenia, aland] }

    private func directory(_ areas: [Country], near: CLLocationCoordinate2D? = nil) -> OfflineCountryDirectory {
        OfflineCountryDirectory(
            listed: OfflineCountries.sortedByName(areas),
            near: near,
            letter: OfflineCountryLetter.ofTheAppLanguage()
        )
    }

    /// - Parameters:
    ///   - downloaded: The areas on the device.
    ///   - unfinished: The areas whose downloads have not finished.
    private func sections(
        _ directory: OfflineCountryDirectory,
        by sort: OfflineCountrySort,
        holding downloaded: Set<String> = [],
        unfinished: Set<String> = []
    ) -> OfflineCountrySections {
        directory.sections(
            by: sort,
            holding: { country in
                if downloaded.contains(country.id) { return .downloaded }
                return unfinished.contains(country.id) ? .unfinished : nil
            },
            byteCount: { $0.byteCount(withDetail: true) }
        )
    }

    // MARK: - By name

    @Test("by name, a country is under the letter its name is filed under, whatever mark the letter carries")
    func lettersFoldMarks() {
        let byName = sections(directory([slovenia, austria, aland]), by: .name)

        #expect(byName.parts == [
            Part(heading: .letter("A"), lines: [.area(aland), .area(austria)]),
            Part(heading: .letter("S"), lines: [.area(slovenia)]),
        ])
    }

    @Test("by name, a country that is held leaves its letter, and a letter left empty goes with it")
    func heldLeavesItsLetter() {
        let byName = sections(directory([slovenia, austria, aland]), by: .name, holding: ["SI", "AX"])

        #expect(byName.downloaded == [aland, slovenia])
        #expect(byName.parts == [Part(heading: .letter("A"), lines: [.area(austria)])])
    }

    // MARK: - Nearest first

    @Test("nearest first lists what is in reach under Nearby and the rest after, a region a line of its own")
    func nearestFirst() {
        let nearest = sections(directory(everything, near: ljubljana), by: .nearest)

        #expect(nearest.downloaded.isEmpty)
        #expect(nearest.parts == [
            Part(heading: .nearby, lines: [.area(slovenia), .area(austria)]),
            Part(heading: .all, lines: [.area(spain), .area(aland), .area(colorado), .area(california)]),
        ])
    }

    @Test("nearest first puts what is held first, nearest first too")
    func nearestFirstHeld() {
        let nearest = sections(directory(everything, near: ljubljana), by: .nearest, holding: ["ES", "AT"])

        #expect(nearest.downloaded == [austria, spain])
        #expect(nearest.parts.first == Part(heading: .nearby, lines: [.area(slovenia)]))
        #expect(nearest.scrollTarget(for: "US-CO").rowID == "US-CO", "a region is a row of its own here")
        #expect(nearest.scrollTarget(for: "US-CO").opening == nil)
    }

    @Test("with no position, nearest first is the list by name")
    func nearestWithoutAPosition() {
        let unplaced = directory(everything)

        #expect(!unplaced.hasPosition)
        #expect(sections(unplaced, by: .nearest) == sections(unplaced, by: .name))
        #expect(sections(unplaced, by: .name).parts.map(\.heading) == [.letter("A"), .letter("S"), .letter("U")])
    }

    // MARK: - Largest first

    @Test("largest first is by what an area takes, by name among equals, what is held first")
    func largestFirst() {
        let all = directory(everything)

        #expect(sections(all, by: .largest).parts == [
            Part(
                heading: .all,
                lines: [california, spain, aland, austria, colorado, slovenia].map { .area($0) }
            ),
        ])
        let held = sections(all, by: .largest, holding: ["SI", "ES"])
        #expect(held.downloaded == [spain, slovenia])
        #expect(held.parts.flatMap(\.lines).map(\.id) == ["US-CA", "AX", "AT", "US-CO"])
    }

    // MARK: - Not yet downloaded

    /// Only what is downloaded draws with no signal (#1533).
    @Test(
        "a download not yet finished is listed first, apart from what is downloaded, in the order's order",
        arguments: [
            (OfflineCountrySort.nearest, ["SI", "ES"]),
            (.name, ["SI", "ES"]),
            (.largest, ["ES", "SI"]),
        ]
    )
    func unfinishedApart(sort: OfflineCountrySort, unfinished: [String]) {
        let all = sections(
            directory(everything, near: ljubljana),
            by: sort,
            holding: ["AT"],
            unfinished: ["ES", "SI"]
        )

        #expect(all.unfinished.map(\.id) == unfinished)
        #expect(all.downloaded == [austria])
        #expect(Set(all.parts.flatMap(\.lines).map(\.id)).isDisjoint(with: ["AT", "ES", "SI"]))
        #expect(all.reveal("ES", expanded: []) == .scroll(to: "ES"))
    }

    // MARK: - The order in force

    @Test("the list opens nearest first where the hiker's position is known, and by name where it is not")
    func openingOrder() {
        #expect(OfflineCountrySort.inForce(chosen: nil, hasPosition: true) == .nearest)
        #expect(OfflineCountrySort.inForce(chosen: nil, hasPosition: false) == .name)
        #expect(OfflineCountrySort.offered(hasPosition: true) == [.nearest, .name, .largest])
        #expect(OfflineCountrySort.offered(hasPosition: false) == [.name, .largest])
    }

    @Test("a chosen order holds, except nearest first once there is no position to measure from")
    func chosenOrder() {
        #expect(OfflineCountrySort.inForce(chosen: .largest, hasPosition: true) == .largest)
        #expect(OfflineCountrySort.inForce(chosen: .name, hasPosition: true) == .name)
        #expect(OfflineCountrySort.inForce(chosen: .largest, hasPosition: false) == .largest)
        #expect(OfflineCountrySort.inForce(chosen: .nearest, hasPosition: false) == .name)
    }

    /// The menu's haptic answers the hiker's choice, not the order in force,
    /// which also turns from by name to nearest first as the position is read.
    @Test("picking the order already in force chooses nothing, and another order is chosen")
    func choosingAnOrder() {
        let list = OfflineCountriesListState()

        list.choose(.nearest, over: .nearest)
        #expect(list.chosenSort == nil)

        list.choose(.largest, over: .nearest)
        #expect(list.chosenSort == .largest)
        list.choose(.largest, over: .largest)
        #expect(list.chosenSort == .largest)
        list.choose(.nearest, over: .largest)
        #expect(list.chosenSort == .nearest)
    }

    // MARK: - A search

    @Test("a search lists a name that starts with it before one that contains it, marks and case aside")
    func searchRanks() {
        let all = directory(everything)

        #expect(all.areas(matching: "al") == [aland, california])
        #expect(all.areas(matching: "SLOV") == [slovenia])
        #expect(all.areas(matching: "xyz").isEmpty)
    }

    @Test("a region answers to its country's name")
    func searchFindsRegionsByCountry() {
        #expect(directory(everything).areas(matching: "united") == [california, colorado])
    }

    // MARK: - Going to an area

    /// A region's row joins the list only on the pass after its country
    /// opens, so a scroll asked for with the opening went nowhere.
    @Test("a region in a closed country opens it first, and is gone to once it is open")
    func revealOpensTheCountryFirst() {
        let byName = sections(directory(everything), by: .name)

        #expect(byName.reveal("US-CO", expanded: []) == .open("US"))
        #expect(byName.reveal("US-CO", expanded: ["US"]) == .scroll(to: OfflineCountrySections.groupRowID("US-CO")))
        #expect(byName.reveal("AT", expanded: []) == .scroll(to: "AT"))
        let nearest = sections(directory(everything, near: ljubljana), by: .nearest)
        #expect(nearest.reveal("US-CO", expanded: []) == .scroll(to: "US-CO"), "a region is a row of its own there")
    }

    // MARK: - Kept across passes

    @Test("the directory is built when the list or the position changes, and kept otherwise")
    func keptAcrossPasses() {
        let cache = OfflineCountryDirectoryCache()

        _ = cache.directory(offered: [austria, slovenia], installed: [:], near: nil)
        _ = cache.directory(offered: [austria, slovenia], installed: [:], near: nil)
        #expect(cache.builds == 1)

        let placed = cache.directory(offered: [austria, slovenia], installed: [:], near: ljubljana)
        _ = cache.directory(offered: [austria, slovenia], installed: [:], near: ljubljana)
        #expect(cache.builds == 2)
        #expect(placed.hasPosition)

        var newer = slovenia
        newer.build = "20270101"
        _ = cache.directory(offered: [austria, newer], installed: [:], near: ljubljana)
        #expect(cache.builds == 3)
    }

    /// The server can correct a name without cutting the area again, and the
    /// rows and the search read the areas the directory kept.
    @Test("a list off the server that renames an area at the same build is named and found by the new name")
    func renamedAtTheSameBuild() {
        let cache = OfflineCountryDirectoryCache()
        var misspelled = california
        misspelled.names = ["en": "Californa"]

        _ = cache.directory(offered: [austria, misspelled], installed: [:], near: nil)
        let refreshed = cache.directory(offered: [austria, california], installed: [:], near: nil)

        #expect(cache.builds == 2)
        #expect(refreshed.entries.map(\.country) == [austria, california])
        #expect(refreshed.areas(matching: "California") == [california])
    }

    @Test("an area downloaded and no longer offered is still listed")
    func keepsWhatIsNoLongerOffered() {
        let cache = OfflineCountryDirectoryCache()
        let installed = ["ES": OfflineCountryStore.Record(country: spain, installedAt: .now)]

        let listed = cache.directory(offered: [austria, slovenia], installed: installed, near: nil)

        #expect(listed.entries.map(\.country) == [austria, slovenia, spain])
        #expect(listed.entries.map(\.fullName) == ["Austria", "Slovenia", "Spain"])
    }
}

// swiftlint:enable no_magic_numbers
