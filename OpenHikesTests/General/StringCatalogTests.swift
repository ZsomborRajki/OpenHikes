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
    nonisolated private static let catalogFolders = [
        "OpenHikes", "OpenWidget", "OpenHikesWatch", "OpenHikesWatchWidgets"
    ]

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

    /// The sentences that used to branch on `count == 1` and now carry their
    /// singular as a variation, where no other suite already reads the
    /// singular back. A key edited without its catalog entry falls back to
    /// the plural wording, which is what these would catch.
    @Test("a sentence that spells out one keeps its singular wording")
    func singularVariationsReadAsWritten() {
        // `CommunityPhotoShareSheet.alreadySent` is private to its view, so
        // this one is read by its key.
        func alreadySent(_ count: Int) -> String {
            String(
                localized: """
                \(count) photos have already been sent from this hike, so they’re \
                left out. Tap one to send it again anyway.
                """
            )
        }
        #expect(alreadySent(1).hasPrefix("One photo has already been sent"))
        #expect(alreadySent(2).hasPrefix("2 photos have already been sent"))
        #expect(CommunityPublishedPhotos.removalWarning(count: 1).hasPrefix("Publishing deletes the faded photo "))
        #expect(CommunityPublishedPhotos.removalWarning(count: 2).hasPrefix("Publishing deletes the 2 faded photos"))
        #expect(CommunityPublishedPhotos.incompleteDownload(missing: 1).hasPrefix("One of this submission’s photos"))
        #expect(CommunityPublishedPhotos.incompleteDownload(missing: 2).hasPrefix("2 of this submission’s photos"))
    }

    /// The singular drops the count but not the trail, so it names the trail
    /// by position (`%2$@`); a plain `%@` there would be handed the count.
    @Test("a singular that drops the count still names the trail")
    func singularKeepsLaterArguments() {
        let one = CommunityPhotoDisclosure.text(photoCount: 1, trailTitle: "Almbachklamm")
        #expect(one.hasPrefix("One photo goes on Almbachklamm, with the spot"))
        let two = CommunityPhotoDisclosure.text(photoCount: 2, trailTitle: "Almbachklamm")
        #expect(two.hasPrefix("2 photos go on Almbachklamm, each with the spot"))
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

    /// One apostrophe, the typographic one (#848). The straight `'` is what a
    /// string typed in a hurry gets, so the catalogs are read from the source
    /// tree and every English value is held to the rule, and
    /// `.swiftlint.yml` holds the literals that never reach a catalog.
    @Test("no English value uses a straight apostrophe", arguments: Self.catalogFolders)
    func catalogsUseTypographicApostrophes(folder: String) throws {
        let offenders = try Self.englishStrings(in: folder).filter { $0.contains("'") }
        #expect(offenders.isEmpty, "straight apostrophes in \(folder): \(offenders.sorted())")
    }

    /// American spelling, the convention #793 settled (#847): "Line Color",
    /// "Center", "License". `.swiftlint.yml`'s `american_spelling_in_copy`
    /// holds the literals; this holds what the catalogs say, which is where a
    /// key edited by hand would keep the old word. The words are the lint
    /// rules' own, read out of that file, so a word added there is checked
    /// here too rather than in one place and not the other.
    @Test("no English value uses a British spelling", arguments: Self.catalogFolders)
    func catalogsUseAmericanSpelling(folder: String) throws {
        let british = try Self.britishSpellings()
        // A control, so a pattern misread out of the file fails here rather
        // than passing every catalog.
        #expect("Line Colour".contains(british))
        let offenders = try Self.englishStrings(in: folder).filter { $0.contains(british) }
        #expect(offenders.isEmpty, "British spellings in \(folder): \(offenders.sorted())")
    }

    /// The checkout this file was compiled from, which the catalogs and the
    /// lint configuration are read out of.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The word list the two spelling rules share, as the
    /// `british_spellings` anchor in `.swiftlint.yml` writes it: one
    /// single-quoted pattern on the anchor's line.
    private static func britishSpellings() throws -> Regex<AnyRegexOutput> {
        let configuration = try String(contentsOf: sourceRoot.appending(path: ".swiftlint.yml"), encoding: .utf8)
        let line = try #require(configuration.split(separator: "\n").first { $0.contains("&british_spellings") })
        let quoted = line.split(separator: "'", omittingEmptySubsequences: false)
        try #require(quoted.count == 3, "expected one single-quoted pattern on: \(line)")
        return try Regex(String(quoted[1]))
    }

    /// Every key of `folder`'s catalog, and every English value under it —
    /// plural and device variations included — read from the source tree.
    private static func englishStrings(in folder: String) throws -> [String] {
        let data = try Data(contentsOf: sourceRoot.appending(path: "\(folder)/Localizable.xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])

        func values(in node: Any) -> [String] {
            guard let dictionary = node as? [String: Any] else { return [] }
            var all = (dictionary["stringUnit"] as? [String: Any])?["value"].map { [$0 as? String ?? ""] } ?? []
            for (key, child) in dictionary where key != "stringUnit" { all += values(in: child) }
            return all
        }

        return strings.flatMap { key, entry -> [String] in
            let english = (entry as? [String: Any])?["localizations"] as? [String: Any]
            return [key] + values(in: english?["en"] as Any)
        }
    }
}
