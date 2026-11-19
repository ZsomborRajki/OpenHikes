//
//  SeededOfflineCountryServer.swift
//  OpenHikes
//
//  A tile server whose manifest lists ten areas and serves none of them.
//
//  ``OfflineCountries/forThisLaunch()`` gives a launch running tests no
//  server and no download session, and rightly: the real manifest is on the
//  OpenHikes tile server, and the files it lists are gigabytes each. But with
//  no server *Offline Maps* says only that this build cannot download
//  countries, so its search, its three orders, its letters and its regions
//  were in front of no UI suite and no accessibility audit.
//
//  This is the third answer between "the real server" and "nothing", on the
//  terms ``SeededCommunityTransport`` set: a launch gets one only by naming a
//  scenario — `--ui-test-offline-countries=<seeded|refused>` — and the whole
//  file is `#if DEBUG`, so no build a person could install contains it.
//
//  ## What is faked, and what is not
//
//  Only the manifest's fetch. The manifest itself is a file in the server's
//  own format, `OfflineCountriesSeed.json` among the UI-test fixtures, read
//  through the decoder the server's answer goes through, and everything
//  downstream of it is the shipping code: ``OfflineCountryManifest``'s
//  readability checks, the directory that names, files and orders the areas,
//  the search, and the outlines on the map.
//
//  **Nothing downloads.** The launch keeps no download session, so
//  ``OfflineCountries/download(_:)`` turns away every area before it asks
//  for a file, and there is no progress to show. The downloads are not
//  stood in for at all: a suite shows the list a hiker chooses from and stops
//  before the download, rather than a download that is not one. And
//  ``url(of:)`` names a host that cannot resolve, so a seed that ever met a
//  session would fail rather than fetch gigabytes from the real server.
//
//  ## What the ten are shaped for
//
//  Coarse outlines of seven countries around the Alps and Norway, and three
//  states of the United States, which is split, so its regions open under
//  it. Germany holds the `ThumseeLoopFast` fixture's trail and no other
//  outline does, so the hike screen's *Offline* tile offers Germany alone.
//  Each order puts a different area first: by name Austria, nearest the
//  Thumsee trailhead Germany, and largest France. The digests are of the
//  file names, not of any file.
//

import Foundation

#if DEBUG

/// A stand-in for the OpenHikes tile server that lists a fixed set of areas.
nonisolated struct SeededOfflineCountryServer: OfflineCountryServing {
    enum Scenario: String, CaseIterable {
        /// The ten areas in `OfflineCountriesSeed.json`.
        case seeded = "seeded"
        /// Every request for the list fails, so the copy a hiker reads when
        /// the server cannot be reached is on screen.
        case refused = "refused"

        /// The scenario a launch argument names, or `nil` for a launch that
        /// did not ask — which is every launch that must get no server.
        init?(argument: String?) {
            guard let argument, let named = Self(rawValue: argument) else { return nil }
            self = named
        }
    }

    enum Failure: Error, Equatable {
        /// The scenario refuses every request.
        case refused
        /// The bundle has no seeded manifest.
        case missingFixture
    }

    static let fixtureName = "OfflineCountriesSeed"

    let scenario: Scenario

    @concurrent
    func manifest() async throws -> OfflineCountryManifest {
        guard scenario == .seeded else { throw Failure.refused }
        guard let url = Bundle.main.url(forResource: Self.fixtureName, withExtension: "json") else {
            throw Failure.missingFixture
        }
        return try JSONDecoder().decode(OfflineCountryManifest.self, from: Data(contentsOf: url))
    }

    /// Somewhere that answers nothing: `.invalid` never resolves.
    func url(of file: OfflineCountryManifest.File) -> URL {
        Self.nowhere.appending(path: "countries/\(file.fileName)")
    }

    // swiftlint:disable:next force_unwrapping
    static let nowhere = URL(string: "https://offline-countries.invalid/")!
}

#endif
