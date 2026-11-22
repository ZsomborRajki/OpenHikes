//
//  OfflineCountryDirectory.swift
//  OpenHikes
//
//  What *Offline Maps* orders and finds its areas by, worked out once for a
//  list rather than at every pass of the view that draws it: each area's
//  name in the app's language, the letter that name is filed under, and how
//  far the area is from the hiker. A name is a `Locale` lookup, a letter a
//  collation's and a distance a walk round an outline; the list is hundreds
//  of areas, and its body runs again at every keystroke in its search field.
//
//  Nor is it worked out in the body, or on the main actor, but for the
//  letters (#1536). Near a known position each area is measured to the
//  nearest point of its outline, and the world's outlines are some 180,000
//  points: 37 to 47 ms on the main actor, in a Debug build on a simulator,
//  as the list opened, as a new list came off the server and as the
//  position was read. So the names, the distances and the orders they give
//  are ``Measured`` off it, and only the letters are filed on it, because
//  the collation they come from is UIKit's: 0.3 ms of the same build
//  (``OfflineCountryDirectoryCache``).
//
//  ## The three orders
//
//  Whatever the order (``OfflineCountrySort``), the areas the hiker has asked
//  for are listed first, in two sections that each keep the order's order:
//  those not yet downloaded, whose download is waiting for Wi-Fi, coming
//  down, being checked or stopped short, and then those downloaded. The two
//  are apart because only the second draws with no signal, and a heading
//  over both said so of the first too (#1533). An area downloaded stays one
//  while an update or its zoom 15 comes down, because what it has draws
//  meanwhile.
//
//  - **By name** the rest is a directory: every country under the letter its
//    name is filed under, which the list's index jumps to, and a country
//    split by region as one line that holds all its regions.
//  - **Nearest first** and **largest first** are flat. A region is a line of
//    its own there, named with its country, because under its country it
//    could not stand where its distance or its size puts it. Nearest first
//    keeps *Nearby* as a heading over the areas a day out reaches. Further
//    off the distance is only good enough to order by: it is measured on a
//    flat map round the hiker (``OfflineCountryManifest/Country/kilometers(from:)``).
//
//  ## A search
//
//  A search is none of the three: the areas whose names answer it, best
//  first by ``HikeNameMatch``'s rule, whatever order the list is in. A region
//  answers to its country's name too, so *United States* finds its states.
//

import Algorithms
import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated struct OfflineCountryDirectory: Sendable {
    typealias Country = OfflineCountryManifest.Country

    /// An area, with what the list reads of it.
    struct Entry: Sendable {
        let country: Country
        /// Its name, with its country's after a region's: what a flat list
        /// and a search call it.
        let fullName: String
        /// How far it is from the hiker, where their position is known.
        let kilometers: Double?
    }

    /// A line of the list by name, with the letter it is filed under.
    private struct Line: Sendable {
        let letter: OfflineCountryLetter
        let listing: OfflineCountryListing
    }

    /// How far *Nearby* reaches.
    static let nearbyKilometers = 250.0

    /// Every area, by name.
    let entries: [Entry]
    /// Whether the hiker's position is known, and with it each area's
    /// distance.
    let hasPosition: Bool
    /// The list by name, in its order.
    private let lines: [Line]
    /// ``entries``' indices, nearest first.
    private let nearestFirst: [Int]

    var isEmpty: Bool { entries.isEmpty }

    /// - Parameters:
    ///   - listed: Every area to list, by name: ``OfflineCountries/listed``.
    ///   - near: Where the hiker is.
    ///   - letter: The letter a name is filed under.
    init(listed: [Country], near: CLLocationCoordinate2D?, letter: (String) -> OfflineCountryLetter) {
        self.init(Measured(listed: listed, near: near), letter: letter)
    }

    /// Every country, and every country split by region with its regions
    /// under it, by letter and then by name: what was `measured`, filed
    /// under the letters `letter` gives.
    init(_ measured: Measured, letter: (String) -> OfflineCountryLetter) {
        entries = measured.entries
        hasPosition = measured.hasPosition
        nearestFirst = measured.nearestFirst
        // In their names' order already, and each letter's group keeps it, so
        // filing is grouping by letter and putting the letters in order.
        let byLetter = measured.named
            .map { Line(letter: letter($0.name), listing: $0.listing) }
            .grouped(by: \.letter.order)
        lines = byLetter.keys.sorted().flatMap { byLetter[$0] ?? [] }
    }
}

nonisolated extension OfflineCountryDirectory {
    /// What a directory is made from: the list off the server, what is
    /// downloaded, and where the hiker was as the list came up.
    struct Source: Equatable, Sendable {
        let offered: [Country]
        let installed: [String: OfflineCountryStore.Record]
        let latitude: Double?
        let longitude: Double?

        init(offered: [Country], installed: [String: OfflineCountryStore.Record], near: CLLocationCoordinate2D?) {
            self.offered = offered
            self.installed = installed
            latitude = near?.latitude
            longitude = near?.longitude
        }

        var near: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// A directory but for its letters: every area's names and distance,
    /// the order nearest first, and the list by name in its names' order.
    /// All a directory costs, and nothing of the main actor's.
    struct Measured: Sendable {
        let entries: [Entry]
        let hasPosition: Bool
        /// ``entries``' indices, nearest first.
        let nearestFirst: [Int]
        /// Every country, and every country split by region as the line
        /// that holds its regions, by name.
        let named: [(name: String, listing: OfflineCountryListing)]

        /// Measures the areas `source` lists: ``OfflineCountries/listed``.
        init(from source: Source) {
            self.init(
                listed: OfflineCountries.listed(offered: source.offered, installed: source.installed),
                near: source.near
            )
        }

        init(listed: [Country], near: CLLocationCoordinate2D?) {
            let measured = listed.map { country in
                Entry(
                    country: country,
                    fullName: OfflineCountries.fullName(of: country),
                    kilometers: near.map { country.kilometers(from: $0) }
                )
            }
            entries = measured
            hasPosition = near != nil
            nearestFirst = measured.indices.sorted { first, second in
                let (one, other) = (measured[first].kilometers ?? .infinity, measured[second].kilometers ?? .infinity)
                return one == other ? first < second : one < other
            }
            named = Self.byName(listed)
        }

        private static func byName(_ listed: [Country]) -> [(name: String, listing: OfflineCountryListing)] {
            var lines: [(name: String, listing: OfflineCountryListing)] = []
            var regions: [String: [Country]] = [:]
            for country in listed {
                if let group = country.group {
                    regions[group, default: []].append(country)
                } else {
                    lines.append((OfflineCountries.name(of: country), .area(country)))
                }
            }
            lines += regions.map { (OfflineCountries.name(ofCountry: $0.key), .group(id: $0.key, regions: $0.value)) }
            return lines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

/// The orders and the search, on the main actor, where the list reads them
/// as it draws.
extension OfflineCountryDirectory {
    // MARK: - The orders

    /// What an order puts at the head of the list, and the rest under its
    /// headings.
    private typealias Ordered = (held: [Country], parts: [OfflineCountrySections.Part])

    /// The list in `sort`'s order: what `holding` says is not yet downloaded,
    /// then what it says is downloaded, then the rest under the order's
    /// headings. By name where the order is nearest first and no position is
    /// known.
    ///
    /// - Parameters:
    ///   - holding: Where an area the hiker has asked for stands, and `nil`
    ///     for every other.
    ///   - byteCount: What an area takes or costs, for largest first.
    func sections(
        by sort: OfflineCountrySort,
        holding: (Country) -> OfflineCountrySections.Holding?,
        byteCount: (Country) -> Int64
    ) -> OfflineCountrySections {
        let isHeld = { holding($0) != nil }
        let ordered: Ordered = switch sort {
        case .nearest where hasPosition: nearest(isHeld: isHeld)
        case .name, .nearest: named(isHeld: isHeld)
        case .largest: largest(isHeld: isHeld, byteCount: byteCount)
        }
        // `partitioned(by:)` answers (does not satisfy, satisfies), and each
        // half keeps the order's order.
        let (downloaded, unfinished) = ordered.held.partitioned { holding($0) == .unfinished }
        return OfflineCountrySections(unfinished: unfinished, downloaded: downloaded, parts: ordered.parts)
    }

    private func largest(isHeld: (Country) -> Bool, byteCount: (Country) -> Int64) -> Ordered {
        // Each measured once, and the name's order kept among equals.
        let sized: [(bytes: Int64, index: Int)] = entries.indices.map { (byteCount(entries[$0].country), $0) }
        let largestFirst = sized
            .sorted { first, second in
                first.bytes == second.bytes ? first.index < second.index : first.bytes > second.bytes
            }
            .map { entries[$0.index].country }
        // `partitioned(by:)` answers (does not satisfy, satisfies), and each
        // half keeps the order above.
        let (rest, held) = largestFirst.partitioned(by: isHeld)
        return (held, Self.parts([(.all, rest)]))
    }

    private func named(isHeld: (Country) -> Bool) -> Ordered {
        let listed = lines.filter { line in
            // A country asked for is listed above. A split country is never
            // one, and keeps every region under it, those asked for too.
            guard case let .area(country) = line.listing else { return true }
            return !isHeld(country)
        }
        // The lines are in their letters' order, so each letter's are a run.
        let parts = listed.chunked(on: \.letter.title).map { title, run in
            OfflineCountrySections.Part(heading: .letter(title), lines: run.map(\.listing))
        }
        return (entries.map(\.country).filter(isHeld), parts)
    }

    private func nearest(isHeld: (Country) -> Bool) -> Ordered {
        var held: [Country] = []
        var nearby: [Country] = []
        var rest: [Country] = []
        for entry in nearestFirst.map({ entries[$0] }) {
            if isHeld(entry.country) {
                held.append(entry.country)
            } else if let kilometers = entry.kilometers, kilometers <= Self.nearbyKilometers {
                nearby.append(entry.country)
            } else {
                rest.append(entry.country)
            }
        }
        return (held, Self.parts([(.nearby, nearby), (.all, rest)]))
    }

    /// Flat parts, each area a line of its own, without the empty ones.
    private static func parts(
        _ headed: [(heading: OfflineCountrySections.Part.Heading, areas: [Country])]
    ) -> [OfflineCountrySections.Part] {
        headed.filter { !$0.areas.isEmpty }
            .map { OfflineCountrySections.Part(heading: $0.heading, lines: $0.areas.map { .area($0) }) }
    }

    // MARK: - A search

    /// The areas whose names answer `query`, best first: a name that starts
    /// with it before one that only contains it.
    func areas(matching query: String) -> [Country] {
        HikeNameMatch.rankedIndices(of: entries.map(\.fullName), matching: query).map { entries[$0].country }
    }
}

/// The letter a name is filed under in a list by name, and where that letter
/// stands among the others.
nonisolated struct OfflineCountryLetter: Sendable {
    let order: Int
    /// What the section it heads, and the list's index, call it.
    let title: String

    /// The letters of the app's language, as the system files a name under
    /// them: `É` under `E` in French, `Ł` after `L` in Polish, and a name
    /// that starts with no letter of the alphabet under `#`, last. On the
    /// main actor, because the collation is UIKit's.
    @MainActor
    static func ofTheAppLanguage() -> (String) -> Self {
        #if canImport(UIKit)
        let collation = UILocalizedIndexedCollation.current()
        let titles = collation.sectionTitles
        return { name in
            let section = collation.section(for: name, collationStringSelector: #selector(NSObject.description))
            return Self(order: section, title: titles.indices.contains(section) ? titles[section] : "#")
        }
        #else
        return { name in
            let initial = name.prefix(1).uppercased()
            return Self(order: Int(initial.unicodeScalars.first?.value ?? 0), title: initial)
        }
        #endif
    }
}

/// What *Offline Maps* lists, in the order it lists it.
struct OfflineCountrySections: Equatable {
    /// Where an area the hiker has asked for stands.
    enum Holding {
        /// It is on the device, whether or not an update or its zoom 15 is
        /// coming down to it.
        case downloaded
        /// Its download has not finished: it is waiting for Wi-Fi, coming
        /// down, being checked or stopped short.
        case unfinished
    }

    /// One heading of the list, and the lines under it.
    struct Part: Equatable, Identifiable {
        enum Heading: Hashable {
            /// Every area not listed above it.
            case all
            /// The countries filed under a letter.
            case letter(String)
            /// The areas within reach of the hiker.
            case nearby
        }

        var heading: Heading
        var lines: [OfflineCountryListing]

        var id: Heading { heading }
    }

    /// What *Not Yet Downloaded* lists: the downloads asked for that have
    /// not finished.
    var unfinished: [OfflineCountryManifest.Country] = []
    /// What *Downloaded* lists: the areas on the device.
    var downloaded: [OfflineCountryManifest.Country] = []
    /// Everything else, under the order's headings.
    var parts: [Part]

    /// Where the list goes to show `id`: its row in *Not Yet Downloaded* or
    /// *Downloaded* if it has one there, else its line further down, opening
    /// the country a region is under.
    func scrollTarget(for id: String) -> (rowID: String, opening: String?) {
        let isID = { (country: OfflineCountryManifest.Country) in country.id == id }
        if unfinished.contains(where: isID) || downloaded.contains(where: isID) { return (id, nil) }
        for line in parts.flatMap(\.lines) {
            if case let .group(group, regions) = line, regions.contains(where: { $0.id == id }) {
                return (Self.groupRowID(id), group)
            }
        }
        return (id, nil)
    }

    /// A region's row under its country, apart from the same region's row at
    /// the head of the list.
    static func groupRowID(_ id: String) -> String { "group-\(id)" }

    /// The list's next step towards showing an area.
    enum Reveal: Equatable {
        /// Open the country the area is under. Its regions join the list on
        /// the pass after, and a scroll asked for before then finds no row to
        /// go to, so the scroll waits for them.
        case open(String)
        /// Go to the row.
        case scroll(to: String)
    }

    /// What the list does next to show `id`, with `expanded` the split
    /// countries already open in it.
    func reveal(_ id: String, expanded: Set<String>) -> Reveal {
        let target = scrollTarget(for: id)
        if let group = target.opening, !expanded.contains(group) { return .open(group) }
        return .scroll(to: target.rowID)
    }
}

/// A line of the list: an area, or a country split by region, which holds
/// all its regions.
nonisolated enum OfflineCountryListing: Equatable, Identifiable, Sendable {
    case area(OfflineCountryManifest.Country)
    case group(id: String, regions: [OfflineCountryManifest.Country])

    var id: String {
        switch self {
        case let .area(country): country.id
        case let .group(id, _): id
        }
    }
}

/// Prepares the directory off the main actor, and keeps it across the list's
/// body passes, which far outnumber the changes to what it is made from: a
/// new list off the server, an area downloaded or deleted, and the hiker's
/// position as the list comes up.
///
/// The body only notes what the list is made from (``revision(for:)``), and
/// the list's task for that revision prepares it (``prepare(_:)``). The
/// directory last prepared stays on screen meanwhile. One is put on screen
/// only while the list is still made from what it was measured from, so a
/// newer list, a download or the position read as the list came up passes
/// over one measured before it, and the list going away cancels it.
///
/// Kept against the areas themselves, not their ids and builds: a list off
/// the server can correct a region's name at the same build, and the rows and
/// the search are read from what was kept. Comparing them costs nothing on a
/// pass that reads the same list, which is the same storage; a refresh that
/// changes nothing walks the areas once, and its storage is kept from then.
/// That is why the comparing is here and the list's task is keyed on the
/// revision: an equal list written over the model's swaps its storage
/// without a word, SwiftUI does not say which of two equal ids it keeps, and
/// keyed on the areas, the task could compare two decodes of the world
/// outline by outline at every pass from then, some 9 ms in a Debug build.
@Observable
final class OfflineCountryDirectoryCache {
    typealias Source = OfflineCountryDirectory.Source
    /// Measures what a directory is made from, wherever it is called.
    typealias Measure = @Sendable (Source) async -> OfflineCountryDirectory.Measured

    /// The directory last prepared, or `nil` until the first is.
    private(set) var directory: OfflineCountryDirectory?
    /// Directories put on screen. A pass that kept one hands back the same
    /// list as a pass that prepared one, so this is what a suite holds the
    /// keeping to.
    @ObservationIgnored private(set) var builds = 0

    /// What the list was last noted to be made from.
    @ObservationIgnored private var asked: Source?
    /// Counts the changes to ``asked``.
    @ObservationIgnored private var askedRevision = 0
    /// The revision ``directory`` was prepared for.
    @ObservationIgnored private var shownRevision: Int?
    @ObservationIgnored private let measure: Measure

    /// - Parameter measure: Measures what a directory is made from: a
    ///   suite's own, to hold a measuring back.
    init(measure: @escaping Measure = { OfflineCountryDirectory.Measured(from: $0) }) {
        self.measure = measure
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Notes what the list is made from, and answers its revision: a new one
    /// only when it changed.
    func revision(for source: Source) -> Int {
        if source != asked { askedRevision += 1 }
        // The storage asked about kept, so that the next pass compares the
        // very same arrays rather than an equal copy, outline by outline.
        asked = source
        return askedRevision
    }

    /// Prepares the directory of `revision`, and puts it on screen unless the
    /// list has changed since or the task was cancelled.
    func prepare(_ revision: Int) async {
        guard revision == askedRevision, revision != shownRevision, let source = asked else { return }
        let measured = await Self.measuring(source, with: measure)
        guard !Task.isCancelled, revision == askedRevision else { return }
        directory = OfflineCountryDirectory(measured, letter: OfflineCountryLetter.ofTheAppLanguage())
        shownRevision = revision
        builds += 1
    }

    @concurrent
    private static func measuring(_ source: Source, with measure: Measure) async -> OfflineCountryDirectory.Measured {
        await measure(source)
    }
}
