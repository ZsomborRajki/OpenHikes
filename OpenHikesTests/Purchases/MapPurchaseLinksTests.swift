//
//  MapPurchaseLinksTests.swift
//  OpenHikesTests
//
//  Which copy of the privacy policy and the terms the app opens, and that
//  every copy it can open is one `Scripts/check-legal-pages.sh` checks.
//
//  That script, not this suite, holds the pages in `docs/` to the links: each
//  one published, in its language, with its original's effective date. A pull
//  request that touches nothing but `docs/` skips every job that builds the
//  app, and those are the pull requests that break the pages, so the check
//  runs as a script in a job no filter skips (*CI* in `AGENTS.md`). It reads
//  the links as the URL literals in `MapPurchaseLinks.swift`; what is left
//  here is that every URL the app opens is one of them. What neither can see
//  is the site itself — a merge not yet deployed, or Pages switched off —
//  which is the reachability App Review checks for.
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
    /// has a case for it, and the page check then fails until `docs/` has the
    /// folder that case links.
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

    /// The page check finds the pages the app links by reading
    /// `MapPurchaseLinks.swift` for quoted URLs, so a URL built any other way
    /// would be a page it never checks.
    @Test("each linked page is a URL the page check reads", arguments: PageLanguage.allCases)
    func linkedPagesAreCheckedPages(language: PageLanguage) throws {
        let source = try String(
            contentsOf: StringCatalogTests.sourceRoot.appending(path: "OpenHikes/Purchases/MapPurchaseLinks.swift"),
            encoding: .utf8
        )
        for url in [language.privacyPolicy, language.termsAndConditions] {
            let site = "https://zsomborrajki.github.io/OpenHikes/"
            #expect(url.absoluteString.hasPrefix(site), "\(url) is not on the site")
            #expect(
                source.contains("\"\(url.absoluteString)\""),
                "\(url) is not spelled out in MapPurchaseLinks.swift, so Scripts/check-legal-pages.sh never checks it"
            )
        }
    }
}
