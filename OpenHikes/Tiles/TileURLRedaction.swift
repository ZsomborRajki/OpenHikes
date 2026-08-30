//
//  TileURLRedaction.swift
//  OpenHikes
//
//  The one representation of a tile URL that may be written to the unified log.
//

import Foundation

nonisolated extension URL {
    /// This URL with every query value replaced by `redacted`, safe to log.
    ///
    /// Tile URLs are the app's only outbound URLs that carry a credential:
    /// Stadia and Thunderforest bill against a key in the query string, so a
    /// resolved tile URL written to the log at `.public` puts a live, billable
    /// key into a sysdiagnose or a screen-shared debug session.
    ///
    /// *Every* value goes, not the ones that look like a credential. Stadia
    /// spells its key `api_key` and Thunderforest spells it `apikey`; the next
    /// provider added to ``TileProvider/all`` will spell it something else
    /// again, and a redaction list that has to be kept in step with the catalog
    /// is one that will eventually be out of step with it. Nothing is lost by
    /// the broad rule: a tile URL carries its z/x/y in the path, so what the
    /// log is actually being asked — which tile, from which host — survives
    /// intact.
    ///
    /// Names are kept so a request can still be told apart from one missing its
    /// key entirely, and a URL with no query is returned unchanged.
    var redactedForLogging: String {
        // A URL the parser can make no sense of is one whose query can't be
        // found, and therefore one whose key can't be shown to be gone. The
        // log gets the host and nothing else rather than a URL nobody vetted.
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "<unparseable \(host() ?? "URL")>"
        }
        guard let items = components.queryItems else { return absoluteString }
        components.queryItems = items.map { item in
            URLQueryItem(name: item.name, value: item.value.map { _ in "redacted" })
        }
        return components.string ?? "<unrenderable \(host() ?? "URL")>"
    }
}
