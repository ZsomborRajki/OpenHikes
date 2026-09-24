//
//  StringCatalogTests.swift
//  OpenHikesTests
//
//  What the app's String Catalog changes at run time, while English is the
//  only language (#32).
//
//  Not whether every string is *in* it. An English key with no English entry
//  of its own is not compiled into the bundle at all — the key is the
//  English, and the runtime falls back to it — so no lookup here can tell a
//  catalogued string from a forgotten one. That question is asked of the
//  source tree instead: `Scripts/sync-string-catalogs.sh --check`.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("String catalog")
struct StringCatalogTests {
    @Test("the app is developed in English")
    func englishIsTheDevelopmentLanguage() {
        #expect(Bundle.main.developmentLocalization == "en")
    }

    /// A count is a plural variation in the catalog, never an `if count == 1`
    /// at the call site: English has two forms and a translation may need
    /// four. The place row's photo count is the first to use one, and it
    /// used to say "1 photos" to VoiceOver.
    @Test("a count reads in the singular for one and the plural for more")
    func countsArePluralVariations() {
        #expect(String(localized: "\(1) photos") == "1 photo")
        #expect(String(localized: "\(3) photos") == "3 photos")
    }

    /// The catalog holds words, never figures: distances, heights and
    /// durations are formatted per locale at the call site, and a catalog
    /// must not freeze one locale's spelling of a unit into English.
    @Test("figures beside a catalogued label stay locale-aware")
    func figuresStayLocaleAware() {
        let meters = Measurement(value: 1500, unit: UnitLength.meters)
        let style = Measurement<UnitLength>.FormatStyle(width: .abbreviated, usage: .road)
        let german = meters.formatted(style.locale(Locale(identifier: "de_DE")))
        let american = meters.formatted(style.locale(Locale(identifier: "en_US")))
        #expect(german != american)
    }
}
