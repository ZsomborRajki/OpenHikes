//
//  OfflineCountries+ThisLaunch.swift
//  OpenHikes
//
//  The countries' model the app itself runs with, and the one a suite's
//  launch gets in its place. Out of `OfflineCountries.swift`, which is at the
//  length the linter allows.
//

import Foundation

extension OfflineCountries {
    /// The app's: the OpenHikes tile server, the background session, the
    /// archives `TileCache.shared` draws from and the standard defaults. A
    /// suite's launch has none of them, and lists nothing, unless a UI
    /// scenario names a stand-in list (``SeededOfflineCountryServer``); even
    /// then it has no session, so nothing downloads.
    static func forThisLaunch() -> OfflineCountries {
        guard !AppLaunchEnvironment.isRunningTests else {
            let countries = OfflineCountries(
                store: OfflineCountryStore(directory: FileManager.default.temporaryDirectory),
                server: seededServer(),
                downloader: nil,
                archives: nil
            )
            seedDownloads(in: countries)
            return countries
        }
        return OfflineCountries(
            store: .applicationSupport(),
            server: OfflineCountryServer.openHikes,
            downloader: BackgroundCountryDownloader.shared,
            archives: .shared,
            defaults: .standard,
            networkDecision: { TileCache.shared.networkDecision(for: .speculative) },
            archivesDidChange: { TileCache.shared.notifyInteractiveFetchUnblocked() }
        )
    }

    /// The stand-in list a UI scenario asked for, or `nil` for every launch
    /// that did not — which is every launch a person could make.
    private static func seededServer() -> (any OfflineCountryServing)? {
        #if DEBUG
        SeededOfflineCountryServer.Scenario(argument: AppLaunchEnvironment.offlineCountriesScenarioName)
            .map { SeededOfflineCountryServer(scenario: $0) }
        #else
        nil
        #endif
    }

    /// Holds as downloaded what the UI scenario this launch named says it
    /// holds, which is nothing for every one but `downloaded`.
    private static func seedDownloads(in countries: OfflineCountries) {
        #if DEBUG
        guard let scenario = SeededOfflineCountryServer.Scenario(
            argument: AppLaunchEnvironment.offlineCountriesScenarioName
        ), scenario == .downloaded,
            let listed = try? SeededOfflineCountryServer(scenario: scenario).listed()
        else { return }
        countries.seed(installed: scenario.downloads(from: listed))
        #endif
    }
}
