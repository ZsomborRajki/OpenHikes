//
//  TileCache+Transport.swift
//  OpenHikes
//
//  How the app introduces itself to a tile server, and what its URLSession
//  will and will not do.
//
//  Split out of `TileCache` because it answers to somebody else's terms
//  rather than to this app's needs: the User-Agent is what OSM's tile usage
//  policy asks for, and the session's caching and connectivity settings are
//  the transport-level half of a policy whose decisions live in
//  `TileNetworkPolicy`. Keeping them together makes the pair of them
//  reviewable against those terms in one place.
//

import Foundation

nonisolated extension TileCache {

    /// The public repository, used as the contact point in ``userAgent``.
    ///
    /// A URL rather than an address: it is already public, it is where an
    /// operator would actually raise a problem, and it can be answered by
    /// whoever is maintaining the app at the time. A personal address would
    /// ship inside every binary and could not be revoked once it had.
    static let repositoryURL = "https://github.com/ZsomborRajki/OpenHikes"

    /// `CFBundleShortVersionString`, or a placeholder for a host that has
    /// none. Xcode generates that key from `MARKETING_VERSION` for every
    /// target here, so the placeholder is only reachable from a bundle that
    /// isn't one of them.
    private static let bundleShortVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// What every tile request says about who is asking.
    ///
    /// OSM's tile usage policy asks for a User-Agent that identifies the
    /// application *and* offers a way to make contact, so that a client
    /// behaving badly can be told rather than only blocked; Overpass's policy
    /// asks the same, and ``OverpassTrailGraphProvider`` sends this string
    /// too. Both halves are therefore load-bearing, not decoration.
    ///
    /// The version is read from the bundle rather than written out, because a
    /// literal is a second place the version lives and the one nobody
    /// remembers to bump — this header announced `1.0` for as long as it was
    /// a literal, whatever the app had shipped since. Named so a test can
    /// assert on the header the app really sends rather than on a copy of the
    /// string.
    static let userAgent = "OpenHikes/\(bundleShortVersion) (iOS; +\(repositoryURL))"

    static func tileSessionConfiguration(
        from configuration: URLSessionConfiguration? = nil
    ) -> URLSessionConfiguration {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A backstop under ``TileNetworkPolicy``, not a substitute for it. The
        // policy stops the request before a connection is opened, which is
        // what saves the radio; this makes sure that a path that somehow
        // reaches here still cannot spend a Low Data Mode allowance on a map
        // tile. There is no matching `allowsExpensiveNetworkAccess = false`
        // because cellular is not a blanket refusal: a tile the walker is
        // looking at still loads over it, and only the reading-ahead the
        // policy classes as speculative does not.
        config.allowsConstrainedNetworkAccess = false
        return config
    }
}
