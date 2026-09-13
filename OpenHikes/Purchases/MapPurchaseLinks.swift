//
//  MapPurchaseLinks.swift
//  OpenHikes
//
//  The documents the app has to be able to open, kept apart from the views
//  that link them. App Review checks that they open something real, and a URL
//  buried in a `Link` in the middle of a layout is a URL nobody re-reads.
//
//  Two of the three are published from this repository and are shown in more
//  than one place — the privacy policy on the paywall and in Settings, the
//  terms in Settings and on the share form — which is the other half of why
//  they are constants: two spellings of the same page are two pages to keep
//  current, and the one nobody edits is the one somebody opens.
//

import Foundation

enum MapPurchaseLinks {
    // Force-unwrapped deliberately, matching `TileAttribution.Credit`: these
    // are compile-time constants, and a typo should fail the tests here rather
    // than quietly remove a link App Review requires.
    // swiftlint:disable force_unwrapping

    /// Apple's standard EULA, which is what governs the subscription unless
    /// OpenHikes publishes its own. Linking it is explicitly allowed, and is
    /// the right answer for an app whose only purchase unlocks a map style —
    /// a bespoke licence agreement would say nothing Apple's does not.
    ///
    /// Replace this only alongside a custom EULA uploaded in App Store
    /// Connect; the two have to describe the same terms.
    static let termsOfUse = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    /// - Important: This has to resolve to a real, reachable page before the
    ///   app is submitted. App Review opens it, and a 404 here fails the
    ///   review for the whole binary rather than just the purchase. It is also
    ///   the URL that goes in the App Privacy section of App Store Connect,
    ///   and the two are expected to match.
    ///
    ///   The page is served from this repository: `docs/privacy/index.html`,
    ///   published by GitHub Pages from `main`. Edit the policy there rather
    ///   than pointing this somewhere else, so the text a reviewer opens and
    ///   the text in the repository cannot drift apart.
    static let privacyPolicy = URL(string: "https://zsomborrajki.github.io/OpenHikes/privacy/")!

    /// This app's own terms — **not** ``termsOfUse``, which is Apple's EULA
    /// for the subscription and governs the purchase alone.
    ///
    /// What lives here and nowhere else is the half of the agreement that has
    /// nothing to do with paying: what a hiker may publish to the community,
    /// the licence they grant by publishing it, what is removed and how, and
    /// how to have something taken down. Until this constant existed the app
    /// linked it from nowhere at all, so the rules a hiker agrees to by
    /// tapping Share were a page they had no way to reach from the screen
    /// they tapped it on.
    ///
    /// Served from this repository — `docs/terms/index.html`, published by
    /// GitHub Pages from `main` — for the reason ``privacyPolicy`` is: edit
    /// the page there rather than pointing this somewhere else, so the text a
    /// reviewer opens and the text in the repository cannot drift.
    static let termsAndConditions = URL(string: "https://zsomborrajki.github.io/OpenHikes/terms/")!

    // swiftlint:enable force_unwrapping
}
