//
//  SeededOfflineCountryServerTests.swift
//  OpenHikesTests
//
//  The stand-in country lists `OfflineMapsUITests`, the *Offline Maps*
//  audit and the App Store frame are built on, checked here so a seed that
//  drifted reports as that —
//  rather than as a UI test that found the wrong row first, which reads as a
//  broken screen.
//
//  Run through the shipping model and directory rather than read back
//  directly, because what the seed has to survive is exactly them: the
//  manifest's readability checks drop an area quietly, and the orders, the
//  regions and the hike screen's tile are worked out from the outlines.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Seeded offline country server")
struct SeededOfflineCountryServerTests {
    /// The `ThumseeLoopFast` trailhead, where the UI tests stand.
    private static let trailhead = CLLocationCoordinate2D(latitude: 47.718420, longitude: 12.831774)
    /// Schönau am Königssee, where the App Store frame stands.
    private static let schoenau = CLLocationCoordinate2D(latitude: 47.592975, longitude: 12.987199)

    private func countries(_ scenario: SeededOfflineCountryServer.Scenario) -> OfflineCountries {
        // A directory that is never made, so the list each test loads is
        // kept nowhere.
        OfflineCountries(
            store: OfflineCountryStore(
                directory: FileManager.default.temporaryDirectory
                    .appending(path: "seeded-countries-\(UUID().uuidString)", directoryHint: .isDirectory)
            ),
            server: SeededOfflineCountryServer(scenario: scenario),
            downloader: nil,
            archives: nil
        )
    }

    private func sections(
        of countries: OfflineCountries,
        by sort: OfflineCountrySort,
        near: CLLocationCoordinate2D?
    ) -> OfflineCountrySections {
        let directory = OfflineCountryDirectory(
            listed: countries.listed,
            near: near,
            letter: OfflineCountryLetter.ofTheAppLanguage()
        )
        return countries.sections(of: directory, by: sort)
    }

    private func firstArea(in sections: OfflineCountrySections) -> String? {
        sections.parts.first?.lines.first?.id
    }

    @Test("only a named scenario produces a server")
    func scenariosAreOptIn() {
        #expect(SeededOfflineCountryServer.Scenario(argument: nil) == nil)
        #expect(SeededOfflineCountryServer.Scenario(argument: "") == nil)
        #expect(SeededOfflineCountryServer.Scenario(argument: "Seeded") == nil)
        for scenario in SeededOfflineCountryServer.Scenario.allCases {
            #expect(SeededOfflineCountryServer.Scenario(argument: scenario.rawValue) == scenario)
        }
    }

    /// Named alongside `--ui-testing`, or absent, as every stand-in is: see
    /// `AppLaunchEnvironmentTests`.
    @Test("a launch argument names the scenario, and only for a UI-testing launch")
    func launchArgumentNamesTheScenario() {
        func scenario(_ arguments: [String], isUITesting: Bool = true) -> SeededOfflineCountryServer.Scenario? {
            SeededOfflineCountryServer.Scenario(
                argument: AppLaunchEnvironment.offlineCountriesScenarioName(
                    askedFor: ["OpenHikes"] + arguments,
                    isUITesting: isUITesting
                )
            )
        }

        #expect(scenario(["--ui-test-offline-countries=seeded"]) == .seeded)
        #expect(scenario(["--ui-test-offline-countries=refused"]) == .refused)
        #expect(scenario(["--ui-test-offline-countries=showcase"]) == .showcase)
        #expect(scenario([]) == nil)
        #expect(scenario(["--ui-test-offline-countries="]) == nil)
        #expect(scenario(["--ui-test-offline-countries=everything"]) == nil)
        #expect(scenario(["--ui-test-offline-countries=seeded"], isUITesting: false) == nil)
        // This very launch is a hosted test, which names none.
        #expect(AppLaunchEnvironment.offlineCountriesScenarioName == nil)
    }

    @Test("every seeded area is one the list keeps")
    func everyAreaIsReadable() async throws {
        let manifest = try await SeededOfflineCountryServer(scenario: .seeded).manifest()

        #expect(manifest.countries.count == 10)
        #expect(manifest.readableCountries == manifest.countries)
    }

    /// The server's own list, as many areas as the deployment state in
    /// AGENTS.md counts, every one of them one the list keeps.
    @Test("the showcase lists every area the server does")
    func showcaseListsEveryArea() async throws {
        let manifest = try await SeededOfflineCountryServer(scenario: .showcase).manifest()

        #expect(manifest.countries.count == 381)
        #expect(manifest.readableCountries == manifest.countries)
    }

    /// What the App Store frame stands on: Germany at the head of the list
    /// nearest Schönau, and the town inside its outline, where a tap on the
    /// map chooses it.
    @Test("nearest Schönau, the showcase leads with Germany")
    func showcaseLeadsWithGermanyNearSchoenau() async throws {
        let countries = countries(.showcase)
        await countries.refreshList()
        let nearest = sections(of: countries, by: .nearest, near: Self.schoenau)

        #expect(nearest.parts.first?.heading == .nearby)
        #expect(nearest.parts.first?.lines.first?.id == "DE")
        let germany = try #require(countries.listed.first { $0.id == "DE" })
        #expect(germany.contains(longitude: Self.schoenau.longitude, latitude: Self.schoenau.latitude))
    }

    @Test("by name, the United States is one line holding its three states")
    func splitCountryHoldsItsRegions() async {
        let countries = countries(.seeded)
        await countries.refreshList()
        let lines = sections(of: countries, by: .name, near: nil).parts.flatMap(\.lines)

        let regions = lines.flatMap { line -> [[String]] in
            guard case let .group(id, regions) = line, id == "US" else { return [] }
            return [regions.map(\.id)]
        }
        #expect(regions == [["US-CO", "US-WA", "US-WY"]])
        #expect(lines.map(\.id) == ["AT", "FR", "DE", "IT", "NO", "SI", "CH", "US"])
    }

    @Test("each order puts a different area first")
    func eachOrderLeadsWithAnotherArea() async {
        let countries = countries(.seeded)
        await countries.refreshList()

        #expect(firstArea(in: sections(of: countries, by: .name, near: nil)) == "AT")
        #expect(firstArea(in: sections(of: countries, by: .largest, near: nil)) == "FR")
        let nearest = sections(of: countries, by: .nearest, near: Self.trailhead)
        #expect(nearest.parts.map(\.heading) == [.nearby, .all])
        #expect(nearest.parts.first?.lines.map(\.id) == ["DE", "AT", "IT", "SI", "CH"])
    }

    @Test("the fixture's trail is in Germany and in no other area")
    func trailIsInGermanyAlone() async throws {
        let countries = countries(.seeded)
        await countries.refreshList()

        let coverage = try await countries.coverage(alongRoute: [RouteCoordinate(Self.trailhead)])
        #expect(coverage.crossed.map(\.id) == ["DE"])
    }

    @Test("a refused list fails, and the seeded one downloads nothing")
    func refusesAndDownloadsNothing() async throws {
        let refused = countries(.refused)
        await refused.refreshList()
        #expect(refused.listPhase == .failed)
        #expect(refused.listed.isEmpty)
        #expect(refused.listsNothing)

        let seeded = countries(.seeded)
        await seeded.refreshList()
        #expect(!seeded.listsNothing)
        let germany = try #require(seeded.listed.first { $0.id == "DE" })
        seeded.download(germany)
        #expect(seeded.downloads.isEmpty)
        #expect(seeded.installed.isEmpty)
    }

    @Test("a file's address reaches no server")
    func addressesResolveNowhere() async throws {
        let manifest = try await SeededOfflineCountryServer(scenario: .seeded).manifest()
        let file = try #require(manifest.countries.first?.files.first)

        let url = SeededOfflineCountryServer(scenario: .seeded).url(of: file)
        #expect(url.host()?.hasSuffix(".invalid") == true)
    }
}
