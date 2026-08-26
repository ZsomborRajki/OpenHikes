//
//  MapPurchaseLinks.swift
//  OpenHikes
//
//  The two documents a paywall has to link to. Kept apart from the view
//  because App Review checks that both open something real, and a URL buried
//  in a `Link` in the middle of a layout is a URL nobody re-reads.
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
    static let privacyPolicy = URL(string: "https://tappium.com/openhikes/privacy")!

    // swiftlint:enable force_unwrapping
}
