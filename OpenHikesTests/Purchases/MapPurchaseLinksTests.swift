//
//  MapPurchaseLinksTests.swift
//  OpenHikesTests
//
//  Which copy of the privacy policy and the terms the app opens, and that
//  every copy it can open is a page this checkout publishes.
//
//  The pages are read out of `docs/`, which GitHub Pages serves at
//  `/OpenHikes/`, rather than fetched: a suite never reaches the network, and a
//  page missing here is a page that 404s once `main` publishes. What this
//  cannot see is the site itself — a merge not yet deployed, or Pages switched
//  off — which is the reachability App Review checks for.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Legal page links")
struct MapPurchaseLinksTests {
    typealias PageLanguage = MapPurchaseLinks.PageLanguage

    @Test("a German app opens the German pages", arguments: ["de", "de-DE", "de-AT", "de-CH", "de_DE"])
    func germanOpensGermanPages(localization: String) {
        let language = PageLanguage(localization: localization)
        #expect(language == .german)
        #expect(language.privacyPolicy.absoluteString == "https://zsomborrajki.github.io/OpenHikes/de/privacy/")
        #expect(language.termsAndConditions.absoluteString == "https://zsomborrajki.github.io/OpenHikes/de/terms/")
    }

    /// The development language, a language the site has no pages in, the
    /// `Base` localization and a missing answer: each reads the site's root.
    @Test("anything else opens the English pages", arguments: ["en", "en-GB", "fr", "Base", nil] as [String?])
    func everythingElseOpensEnglishPages(localization: String?) {
        let language = PageLanguage(localization: localization)
        #expect(language == .english)
        #expect(language.privacyPolicy.absoluteString == "https://zsomborrajki.github.io/OpenHikes/privacy/")
        #expect(language.termsAndConditions.absoluteString == "https://zsomborrajki.github.io/OpenHikes/terms/")
    }

    /// A language the app ships with no pages of its own is a screen in that
    /// language opening a policy in another, which is what the German pages
    /// exist to end. Adding a localization fails here until ``PageLanguage``
    /// has a case for it and `docs/` the folder that case links.
    @Test("every language the app ships has pages of its own")
    func everyShippedLanguageHasPages() throws {
        let shipped = Bundle.main.localizations.filter { $0 != "Base" }
        try #require(shipped.contains("de"), "the bundle lists \(shipped), without the German these pages translate")
        for localization in shipped {
            let code = Locale.Language(identifier: localization).languageCode?.identifier
            #expect(
                code.flatMap(PageLanguage.init(rawValue:)) != nil,
                "OpenHikes ships \(localization), and its privacy policy and terms have no pages in it"
            )
        }
    }

    @Test("each linked page is published from docs/ in its own language", arguments: PageLanguage.allCases)
    func linkedPagesArePublishedHere(language: PageLanguage) throws {
        for url in [language.privacyPolicy, language.termsAndConditions] {
            let html = try Self.page(at: url)
            #expect(html.contains("<html lang=\"\(language.rawValue)\">"), "\(url) is not marked as \(language)")
        }
    }

    /// The cost of publishing two copies is the one nobody updates: the
    /// English page changes, and the German goes on promising what the app no
    /// longer does. Each page states the date it took effect in a single
    /// `<time datetime>`, so an English change that moves its date fails here
    /// until the translation says the same.
    @Test(
        "each translation takes effect with its original",
        arguments: PageLanguage.allCases.filter { $0 != .english }
    )
    func translationsTakeEffectWithTheirOriginals(language: PageLanguage) throws {
        #expect(
            try Self.effectiveDate(of: language.privacyPolicy)
                == Self.effectiveDate(of: PageLanguage.english.privacyPolicy),
            "the \(language) privacy policy was not updated with the English one"
        )
        #expect(
            try Self.effectiveDate(of: language.termsAndConditions)
                == Self.effectiveDate(of: PageLanguage.english.termsAndConditions),
            "the \(language) terms were not updated with the English ones"
        )
    }

    /// The file GitHub Pages serves `url` from: the site publishes `docs/` at
    /// `/OpenHikes/`, and a folder's page is its `index.html`.
    private static func page(at url: URL) throws -> String {
        let site = "/OpenHikes/"
        try #require(url.host() == "zsomborrajki.github.io" && url.path().hasPrefix(site), "\(url) is not on the site")
        let folder = url.path().dropFirst(site.count)
        let file = StringCatalogTests.sourceRoot.appending(path: "docs/\(folder)index.html")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The `datetime` of the page's one `<time>` element.
    private static func effectiveDate(of url: URL) throws -> Substring {
        let html = try page(at: url)
        let marker = "<time datetime=\""
        let parts = html.components(separatedBy: marker)
        try #require(parts.count == 2, "\(url) should state exactly one effective date")
        let start = try #require(html.range(of: marker)).upperBound
        let end = try #require(html[start...].firstIndex(of: "\""))
        return html[start..<end]
    }
}
