//
//  OfflineCountryServer.swift
//  OpenHikes
//
//  Where the countries to download are listed and kept: beside the tiles, on
//  the OpenHikes tile server, which serves `countries/manifest.json` and each
//  file it names, with ranges so a download resumes where it stopped.
//

import Foundation

/// Where the manifest and the files are. A suite hands the model its own.
protocol OfflineCountryServing: Sendable {
    /// `@concurrent`, here rather than only on the server's, because off the
    /// main actor is the promise: the manifest carries every area's outline,
    /// megabytes of it, and every caller is on the main actor, where a plain
    /// `nonisolated async` function would decode it.
    @concurrent
    func manifest() async throws -> OfflineCountryManifest
    func url(of file: OfflineCountryManifest.File) -> URL
}

/// The OpenHikes tile server.
nonisolated struct OfflineCountryServer: OfflineCountryServing {
    // swiftlint:disable:next force_unwrapping
    static let openHikes = Self(root: URL(string: "https://tiles.openhikes.app/")!)
    static let manifestPath = "countries/manifest.json"
    static let requestTimeout: TimeInterval = 20

    let root: URL

    enum Failure: Error {
        case status(Int)
    }

    @concurrent
    func manifest() async throws -> OfflineCountryManifest {
        var request = URLRequest(
            url: root.appending(path: Self.manifestPath),
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == Self.httpOK else { throw Failure.status(status) }
        return try JSONDecoder().decode(OfflineCountryManifest.self, from: data)
    }

    /// Where `file` is: under `countries/`, by its name, which is the only
    /// place the server's route serves a country from.
    func url(of file: OfflineCountryManifest.File) -> URL {
        root.appending(path: "countries/\(file.fileName)")
    }

    private static let httpOK = 200
}
