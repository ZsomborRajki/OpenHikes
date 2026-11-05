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
//  ## In the language the app speaks
//
//  Those two are published in English, German, French, Spanish and Italian,
//  and the app opens the copy in its own language (``PageLanguage``). A German
//  screen that says *Datenschutzerklärung* and opens an English page fails the
//  reader the policy is written for: the GDPR asks for information its
//  audience can understand, and the transparency guidelines the EDPB endorsed
//  ask for a translation wherever a service addresses speakers of another
//  language. The terms have a sharper reason. German consumers are not bound
//  by terms in a language they cannot be expected to read — the Kammergericht
//  held WhatsApp's English-only terms void for exactly that (KG Berlin,
//  5 U 156/14) — and the licence a hiker grants by tapping Share is in them.
//  France asks for the same in statute: the Toubon law (loi n° 94-665)
//  requires French for the description and the terms of a service offered
//  there, so the French app opens French pages too. Mexico's consumer law
//  goes further: a contract of adhesion made there is valid only if it is
//  written in Spanish (Ley Federal de Protección al Consumidor, art. 85), so
//  the Spanish app opens Spanish pages, wherever its reader is. Italy's
//  consumer code asks it of everything a consumer is told, which it requires
//  at least in Italian (Codice del consumo, D.Lgs. 206/2005, art. 9), so the
//  Italian app opens Italian pages.
//
//  Apple's EULA stays one URL, because it is Apple's text and not this app's
//  to translate.
//

import Foundation

enum MapPurchaseLinks {
    // Force-unwrapped deliberately, matching `TileAttribution.Credit`: these
    // are compile-time constants, and a typo should fail the tests here rather
    // than quietly remove a link App Review requires.
    // swiftlint:disable force_unwrapping

    /// The languages the privacy policy and the terms are published in, and
    /// the one the app opens them in.
    ///
    /// English is the site's root, and each translation is a folder named
    /// for its language, page for page: German is `docs/de/`, French
    /// `docs/fr/`, Spanish `docs/es/` and Italian `docs/it/`, so
    /// `docs/it/privacy/index.html` translates `docs/privacy/index.html`, and
    /// `docs/it/terms/index.html` translates `docs/terms/index.html`. Each
    /// translation carries its original's effective date, so an English change
    /// that bumps the date fails `Scripts/check-legal-pages.sh` until every
    /// translation says the same. That script finds the pages by reading the
    /// quoted URLs below, so spell each one out. A language the app ships has
    /// to be a case here with a folder there; `MapPurchaseLinksTests` fails on
    /// one that is not a case, and the script on a folder that is missing.
    nonisolated enum PageLanguage: String, CaseIterable, Sendable {
        case english = "en"
        case french = "fr"
        case german = "de"
        case italian = "it"
        case spanish = "es"

        /// The language the app is running in: the localization the bundle
        /// chose from the hiker's preferred languages, which is the one every
        /// string on the screen linking a page was looked up in. Read once, as
        /// those strings are — iOS relaunches an app whose language changes.
        static let app = Self(localization: Bundle.main.preferredLocalizations.first)

        /// English unless the localization's language has pages of its own,
        /// because English is the development language and the pages at the
        /// site's root are English. A regional variant reads its language's
        /// pages, so `de-AT` and `de-CH` open the German ones, `fr-CA` and
        /// `fr-CH` the French ones, `es-MX` and `es-419` the Spanish ones, and
        /// `it-CH` the Italian ones.
        init(localization: String?) {
            let code = localization.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
            self = code.flatMap(Self.init(rawValue:)) ?? .english
        }

        var privacyPolicy: URL {
            switch self {
            case .english: URL(string: "https://zsomborrajki.github.io/OpenHikes/privacy/")!
            case .french: URL(string: "https://zsomborrajki.github.io/OpenHikes/fr/privacy/")!
            case .german: URL(string: "https://zsomborrajki.github.io/OpenHikes/de/privacy/")!
            case .italian: URL(string: "https://zsomborrajki.github.io/OpenHikes/it/privacy/")!
            case .spanish: URL(string: "https://zsomborrajki.github.io/OpenHikes/es/privacy/")!
            }
        }

        var termsAndConditions: URL {
            switch self {
            case .english: URL(string: "https://zsomborrajki.github.io/OpenHikes/terms/")!
            case .french: URL(string: "https://zsomborrajki.github.io/OpenHikes/fr/terms/")!
            case .german: URL(string: "https://zsomborrajki.github.io/OpenHikes/de/terms/")!
            case .italian: URL(string: "https://zsomborrajki.github.io/OpenHikes/it/terms/")!
            case .spanish: URL(string: "https://zsomborrajki.github.io/OpenHikes/es/terms/")!
            }
        }
    }

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
    ///   and the two are expected to match — the English page for the English
    ///   localization there, the German page for the German one, and so on
    ///   for French, Spanish and Italian.
    ///
    ///   The page is served from this repository: `docs/privacy/index.html`,
    ///   or `docs/de/privacy/index.html` in German, `docs/fr/privacy/index.html`
    ///   in French, `docs/es/privacy/index.html` in Spanish and
    ///   `docs/it/privacy/index.html` in Italian, published by GitHub Pages from
    ///   `main`. Edit the policy there rather than pointing
    ///   this somewhere else, so the text a reviewer opens and the text in the
    ///   repository cannot drift apart.
    static let privacyPolicy = PageLanguage.app.privacyPolicy

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
    /// Served from this repository — `docs/terms/index.html`, or
    /// `docs/de/terms/index.html` in German, `docs/fr/terms/index.html` in
    /// French, `docs/es/terms/index.html` in Spanish and
    /// `docs/it/terms/index.html` in Italian, published by GitHub Pages from
    /// `main` — for the reason
    /// ``privacyPolicy`` is: edit the page there rather than pointing this
    /// somewhere else, so the text a reviewer opens and the text in the
    /// repository cannot drift.
    static let termsAndConditions = PageLanguage.app.termsAndConditions

    // swiftlint:enable force_unwrapping
}
