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
                \(count) photos have already been sent from this hike, so they're \
                left out. Tap one to send it again anyway.
                """
            )
        }
        #expect(alreadySent(1).hasPrefix("One photo has already been sent"))
        #expect(alreadySent(2).hasPrefix("2 photos have already been sent"))
        #expect(CommunityPublishedPhotos.removalWarning(count: 1).hasPrefix("Publishing deletes the faded photo "))
        #expect(CommunityPublishedPhotos.removalWarning(count: 2).hasPrefix("Publishing deletes the 2 faded photos"))
        #expect(CommunityPublishedPhotos.incompleteDownload(missing: 1).hasPrefix("One of this submission's photos"))
        #expect(CommunityPublishedPhotos.incompleteDownload(missing: 2).hasPrefix("2 of this submission's photos"))
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
}
