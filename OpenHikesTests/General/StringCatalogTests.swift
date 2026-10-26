//
//  StringCatalogTests.swift
//  OpenHikesTests
//
//  What the app's String Catalog changes at run time in English, the
//  development language (#32). The German is held to the English in
//  `StringCatalogTests+German.swift`.
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
    nonisolated static let catalogFolders = [
        "OpenHikes", "OpenWidget", "OpenHikesWatch", "OpenHikesWatchWidgets"
    ]

    /// The ceiling ``catalogsKeepCopyShort(folder:)`` holds copy under: a
    /// little above the longest message the app needs, which is a
    /// reviewer's alert about a take-down that only half finished.
    nonisolated private static let longestCopy = 220

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
        // The hike detail's offline notes, which `OfflineDownloadStatus` and
        // `OfflineStorageStatus` word privately, so these are read by key too.
        #expect(String(localized: "Saving \(1) tiles…") == "Saving 1 tile…")
        #expect(String(localized: "Saving \(2) tiles…") == "Saving 2 tiles…")
        #expect(
            String(localized: "Auto-saved \(1) tiles near the trail — storage limit reached.")
                == "Auto-saved 1 tile near the trail — storage limit reached."
        )
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

    /// Copy is a simple explanation (*Platform contracts* in the repository
    /// instructions): what a control does, or what happened and what to do
    /// next. Settings once carried a reminders footer of over six hundred
    /// characters, most of a phone's screen in footnote type, and a Health
    /// footer of eight lines. A sentence or two fits under this ceiling; a
    /// footer like either of those does not.
    @Test("no English value runs past a sentence or two", arguments: Self.catalogFolders)
    func catalogsKeepCopyShort(folder: String) throws {
        let long = try Self.englishStrings(in: folder).filter { $0.count > Self.longestCopy }
        #expect(long.isEmpty, "copy over \(Self.longestCopy) characters in \(folder): \(long.sorted())")
    }

    /// The word `WatchRecordingFiguresTests` cannot reach (#1028). The watch
    /// once drew its average speed under "Pace", a word for time per
    /// distance. The shared package now picks only which caption a figure
    /// takes; the words are the watch target's, in
    /// `WatchRecordingFigures+Caption.swift`, and the watch has no test
    /// bundle. A caption put back to "Pace" fails
    /// `sync-string-catalogs.sh --check` only until the next sync, which adds
    /// "Pace" and deletes "Avg Speed", or keeps it marked stale if it ever
    /// carries a translated value. So this reads the catalog that sync leaves
    /// behind, and fails either way.
    @Test("the watch captions its average as a speed, as the phone does")
    func watchCaptionsTheAverageAsASpeed() throws {
        let strings = try Self.catalog(in: "OpenHikesWatch")
        let speed = try #require(strings["Avg Speed"] as? [String: Any])
        #expect(speed["extractionState"] as? String != "stale")
        #expect(strings["Pace"] == nil)
    }

    /// What VoiceOver reads the watch's average by, which its tile shortens
    /// to "Avg Speed" (*Settled decisions* in the repository instructions).
    /// Read out of the catalog for the reason the test above gives: the words
    /// are the watch target's, and a sync deletes a key no build extracts.
    @Test("the watch speaks its average in full, as the phone does")
    func watchSpeaksTheAverageInFull() throws {
        let strings = try Self.catalog(in: "OpenHikesWatch")
        let spoken = try #require(strings["Average Speed"] as? [String: Any])
        #expect(spoken["extractionState"] as? String != "stale")
    }

    /// Words Settings, iCloud sync and offline maps once handed through a
    /// bare `String`, which drew them verbatim and listed them nowhere
    /// (#1028). One for each way that happened: a footer joined with `+`, a
    /// row named through a helper's `String` parameter, a value
    /// `LabeledContent` drew as it was, a spoken hint, a status a model
    /// words, a map style's name and its license holder's, and the messages
    /// an offline download fails with. Put back as a bare literal, each fails
    /// `sync-string-catalogs.sh --check` only until the next sync deletes its
    /// key, so, as for the watch's caption above, this reads the catalog that
    /// sync leaves behind.
    @Test("the settings, sync and offline-map words are in the app's catalog", arguments: [
        "Maps with a lock need OpenHikes Pro.",
        "Map cache",
        "Subscribed",
        "Requires OpenHikes Pro. Opens the subscription screen.",
        "OpenHikes doesn’t have Always location access, so this can’t run. Turn it on in Settings.",
        "Sync Off",
        "Last synced %@.",
        "Apple Satellite",
        "Stadia Maps",
        "Nothing to save.",
        "Saved %lld of %lld tiles. Try again to finish the download.",
        "OpenHikes couldn’t read the other hikes’ offline coverage. No tiles were deleted.",
    ])
    func settingsWordsReachTheCatalog(key: String) throws {
        let strings = try Self.catalog(in: "OpenHikes")
        let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the app's catalog")
        #expect(entry["extractionState"] as? String != "stale")
    }

    /// Words the hike detail, the library's totals, a walk's summary and the
    /// live recording once handed through a bare `String` (#1028). One for
    /// each way that happened: a ``Stat`` caption and what it is spoken as, a
    /// caption written straight into a ``StatRow``, ``StatList``'s own
    /// heading, a metadata row's label, a heading and a record named through a
    /// helper's `String` parameter, a word a value or an outcome hands back, a
    /// clause of a spoken value, and a note joined with `+`. Read from the
    /// catalog for the reason the settings words above are.
    @Test("the hike detail, totals and walk words are in the app's catalog", arguments: [
        "Elevation Gain",
        "Moving Average Speed",
        "Current Speed",
        "Statistics",
        "Keywords",
        "All Time",
        "Steepest",
        "Stopped",
        "Left open",
        "about %@ to go",
        "This trail has changed since the hike, so the stretches it covered can no longer be drawn along it.",
    ])
    func hikeDetailWordsReachTheCatalog(key: String) throws {
        let strings = try Self.catalog(in: "OpenHikes")
        let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the app's catalog")
        #expect(entry["extractionState"] as? String != "stale")
    }

    /// The checkout this file was compiled from, which the catalogs, the
    /// lint configuration and the sources they translate are read out of.
    static var sourceRoot: URL {
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

    /// `folder`'s catalog for `table` as the source tree has it: every key,
    /// with its entry.
    static func catalog(in folder: String, table: String = "Localizable") throws -> [String: Any] {
        let data = try Data(contentsOf: sourceRoot.appending(path: "\(folder)/\(table).xcstrings"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: Any])
    }

    /// Every key of `folder`'s catalog, and every English value under it —
    /// plural and device variations included — read from the source tree.
    private static func englishStrings(in folder: String) throws -> [String] {
        let strings = try catalog(in: folder)

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
