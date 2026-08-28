//
//  TileAttribution.swift
//  OpenHikes
//
//  Who has to be credited for a tile source, and where each credit's licence
//  lives. Modelled rather than spelled as one string because every provider
//  here requires the credit to be *linked*, not merely present:
//
//  - OpenStreetMap's attribution guidelines require the licence to be
//    reachable from the credit.
//  - Thunderforest: "Users of your site/application must have a working links
//    to www.thunderforest.com and www.openstreetmap.org/copyright".
//  - Stadia's terms forbid "obscuring or attempting to obscure any
//    attributions", and their attribution docs require the credit stay
//    "prominent".
//
//  A plain `String` could satisfy none of that, which is what this replaces.
//

import Foundation

/// The credits a tile source must display, in the order they must appear.
nonisolated struct TileAttribution: Hashable, Sendable {
    /// One credited party.
    struct Credit: Hashable, Sendable, Identifiable {
        /// The words that carry the link, e.g. `"Thunderforest"`.
        let title: String
        /// Text placed before ``title``, e.g. `"Maps ©"`. Held separately so
        /// the copyright symbol is never part of the tappable region.
        let prefix: String
        /// The licence or homepage the credit must reach.
        ///
        /// `nil` for a party the app cannot link itself: Apple's base map is
        /// credited by MapKit's own **Legal** link, which is drawn by the map
        /// view and is not ours to reproduce.
        let url: URL?
        /// The shortest naming of this party its licensor sanctions, for the
        /// one placement that is genuinely space-constrained — see
        /// ``TileAttribution/compactText``. Defaults to ``title``, so a credit
        /// only carries one where a shorter form is actually permitted.
        let compactTitle: String

        var id: String { title }

        /// The credit as one run of text, for anywhere a link cannot be drawn
        /// — VoiceOver, a share sheet, an exported file.
        var plainText: String { "\(prefix) \(title)" }

        init(title: String, prefix: String, url: URL?, compactTitle: String? = nil) {
            self.title = title
            self.prefix = prefix
            self.url = url
            self.compactTitle = compactTitle ?? title
        }
    }

    let credits: [Credit]

    init(_ credits: [Credit]) {
        self.credits = credits
    }

    /// Every credit joined the way the providers write them in their own terms.
    /// This is the exact string the app displayed before the credits became
    /// linkable, and it stays the spoken form.
    var plainText: String {
        credits.map(\.plainText).joined(separator: ", ")
    }

    /// Whether anything here can actually be opened. False only for the system
    /// base map, whose single credit MapKit draws its own link for.
    var hasLinks: Bool {
        credits.contains { $0.url != nil }
    }

    /// The same parties, named once each behind a single `©`, for the credit
    /// line drawn *on the map*.
    ///
    /// Only the decoration is dropped, never a party: the OSMF's guidelines
    /// permit a shortened credit for a space-constrained placement but require
    /// it to stay "legible and understandable", and Thunderforest's terms name
    /// both parties outright. So `Maps © Thunderforest, Data © OpenStreetMap
    /// contributors` becomes `© Thunderforest, OpenStreetMap` — two names, two
    /// links, forty per cent of the width, and one line at most Dynamic Type
    /// sizes instead of three.
    ///
    /// ``plainText`` remains the canonical form and is what Settings draws and
    /// what VoiceOver speaks, both of which have the room. Every credit the app
    /// draws here is a copyright notice, which is what lets one symbol lead.
    var compactText: String {
        "© " + credits.map(\.compactTitle).joined(separator: ", ")
    }
}

nonisolated extension TileAttribution.Credit {
    // Force-unwrapped deliberately: these are compile-time constants, and a
    // typo in one should fail the attribution tests immediately rather than
    // silently drop the licence link a provider's terms require.
    // swiftlint:disable force_unwrapping
    // "OpenStreetMap" alone (rather than "OpenStreetMap contributors") is the
    // shortened form the OSM Foundation's attribution guidelines explicitly
    // sanction for space-constrained placements, provided the credit still
    // links to the copyright page — which this one does.
    static let openStreetMap = Self(
        title: "OpenStreetMap",
        prefix: "©",
        url: URL(string: "https://www.openstreetmap.org/copyright")!
    )

    static let stadiaMaps = Self(
        title: "Stadia Maps",
        prefix: "©",
        url: URL(string: "https://stadiamaps.com/")!
    )

    static let openMapTiles = Self(
        title: "OpenMapTiles",
        prefix: "©",
        url: URL(string: "https://openmaptiles.org/")!
    )

    static let thunderforest = Self(
        title: "Thunderforest",
        prefix: "Maps ©",
        url: URL(string: "https://www.thunderforest.com")!
    )

    /// Thunderforest requires the OSM credit to read "Data ©" beside its own
    /// "Maps ©", which is why this exists alongside ``openStreetMap``.
    ///
    /// Its compact form drops "contributors" rather than the party: that is
    /// the shortening the OSMF's guidelines sanction for a space-constrained
    /// placement, provided the credit still links to the copyright page — and
    /// it is the same form ``openStreetMap`` above already uses.
    static let openStreetMapData = Self(
        title: "OpenStreetMap contributors",
        prefix: "Data ©",
        url: URL(string: "https://www.openstreetmap.org/copyright")!,
        compactTitle: "OpenStreetMap"
    )
    // swiftlint:enable force_unwrapping

    static let apple = Self(title: "Apple", prefix: "Map data ©", url: nil)
}
