//
//  StringCatalogTests+Translations.swift
//  OpenHikesTests
//
//  The translations, German, French, Spanish, Italian and Russian, read out
//  of the source tree like the rest of this suite. A key with no translation
//  falls back to English without a word, and a translated value that drops or
//  retypes a placeholder formats the wrong argument. Neither shows anywhere
//  else, because the hosted tests run in English.
//
//  The Info.plist and App Shortcuts catalogs have no sync to keep them
//  current: the IDE extracts into them, `xcodebuild` does not, and
//  `Scripts/sync-string-catalogs.sh` covers the `Localizable` tables only.
//  So two tests hold each one to what it translates, and a permission prompt
//  or a Siri phrase edited without its catalog fails here.
//
//  Every check runs once per language in ``translations``, so a language
//  added there is held to everything German is.
//

import Foundation
import Testing

extension StringCatalogTests {
    /// The languages the app ships besides English, its development language.
    nonisolated static let translations = ["de", "fr", "es", "it", "ru"]

    /// The languages whose `one` form is handed more than 1. French reads
    /// zero as singular. Russian reads every number that ends in 1 as
    /// singular, 11 aside: 21, 31, 101.
    nonisolated static let countedSingulars = ["fr", "ru"]

    @Test("every catalogued string is translated", arguments: Self.catalogFolders, Self.translations)
    func everyStringIsTranslated(folder: String, language: String) throws {
        let missing = try Self.untranslated(into: language, in: Self.catalog(in: folder))
        #expect(missing.isEmpty, "no \(language) in \(folder) for: \(missing.sorted())")
    }

    /// An Info.plist catalog holds more than the prompts checked below: the
    /// IDE extracts the bundle's name into it, and the name Files shows for a
    /// GPX file. Each needs a translation, or to be marked as not translated.
    @Test(
        "every Info.plist string is translated",
        arguments: ["OpenHikes", "OpenHikesWatch"], Self.translations
    )
    func everyInfoPlistStringIsTranslated(folder: String, language: String) throws {
        let missing = try Self.untranslated(into: language, in: Self.catalog(in: folder, table: "InfoPlist"))
        #expect(missing.isEmpty, "no \(language) in \(folder)/InfoPlist.xcstrings for: \(missing.sorted())")
    }

    @Test(
        "a translation keeps the placeholders its English is handed",
        arguments: Self.catalogFolders, Self.translations
    )
    func translationKeepsThePlaceholders(folder: String, language: String) throws {
        var offenders: [String] = []
        for (key, value) in try Self.catalog(in: folder) {
            let entry = value as? [String: Any] ?? [:]
            let translated = Self.localization(language, of: entry)
            if translated.isEmpty { continue }
            let english = Self.placeholders(in: Self.english(of: key, entry))
            let forms = Self.forms(of: translated)
            let isPlural = Self.localization("en", of: entry)["variations"] != nil
            if forms.isEmpty || (isPlural && translated["variations"] == nil) {
                offenders.append(key)
            }
            for (form, text) in forms {
                let found = Self.placeholders(in: text)
                // A singular may leave the count out, as "One photo goes on %2$@" does.
                let fits = form == "one" ? Set(found).isSubset(of: english) : found.sorted() == english.sorted()
                if !fits { offenders.append("\(key) → \(text)") }
            }
        }
        #expect(offenders.isEmpty, "\(language) in \(folder) its English cannot fill: \(offenders.sorted())")
    }

    /// French reads zero as singular, so its `one` form is handed 0 as well
    /// as 1, and a singular that spells out the count as a word, as English
    /// "One photo goes on %2$@" does, would tell a hiker with no photos that
    /// one goes. Russian would tell a hiker with 21 that one does. Their
    /// singular keeps the number.
    @Test(
        "a singular keeps its count where it is handed more than 1",
        arguments: Self.catalogFolders, Self.countedSingulars
    )
    func singularKeepsTheCount(folder: String, language: String) throws {
        var offenders: [String] = []
        for (key, value) in try Self.catalog(in: folder) {
            let entry = value as? [String: Any] ?? [:]
            let translated = Self.localization(language, of: entry)
            guard translated["variations"] != nil else { continue }
            let english = Self.placeholders(in: Self.english(of: key, entry))
            let counts = Set(english.filter { !$0.hasSuffix(":@") && !$0.hasSuffix(":f") })
            for (form, text) in Self.forms(of: translated) where form == "one" {
                if !counts.isSubset(of: Set(Self.placeholders(in: text))) {
                    offenders.append("\(key) → \(text)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(language) singulars in \(folder) that drop their count: \(offenders.sorted())")
    }

    /// Russian counts in three forms: 1 поход, 2 похода, 5 походов. A plural
    /// with no `few` or no `many` falls back to `other` without a word, and
    /// reads «5 похода».
    @Test("a Russian plural has a form for one, for few and for many", arguments: Self.catalogFolders)
    func russianPluralHasEveryForm(folder: String) throws {
        var offenders: [String] = []
        for (key, value) in try Self.catalog(in: folder) {
            let russian = Self.localization("ru", of: value as? [String: Any] ?? [:])
            guard russian["variations"] != nil else { continue }
            let missing = Set(["one", "few", "many", "other"]).subtracting(Self.forms(of: russian).map(\.form))
            if !missing.isEmpty { offenders.append("\(key) lacks \(missing.sorted())") }
        }
        #expect(offenders.isEmpty, "Russian plurals in \(folder) short of a form: \(offenders.sorted())")
    }

    @Test(
        "every permission prompt is translated, for the English its Info.plist has",
        arguments: ["OpenHikes", "OpenHikesWatch"], Self.translations
    )
    func permissionPromptsAreTranslated(folder: String, language: String) throws {
        let data = try Data(contentsOf: Self.sourceRoot.appending(path: "\(folder)/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try #require(plist as? [String: Any])
        // Each purpose string, and each precise-location purpose, which Core
        // Location looks up in the same table by its key.
        var prompts = info.filter { $0.key.hasSuffix("UsageDescription") }.compactMapValues { $0 as? String }
        let purposes = info["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: String] ?? [:]
        prompts.merge(purposes) { prompt, _ in prompt }
        try #require(!prompts.isEmpty, "no purpose strings read out of \(folder)/Info.plist")
        let strings = try Self.catalog(in: folder, table: "InfoPlist")
        for (key, english) in prompts {
            let entry = strings[key] as? [String: Any] ?? [:]
            let listed = Self.forms(of: Self.localization("en", of: entry)).first?.text
            #expect(listed == english, "\(folder)/InfoPlist.xcstrings has other English for \(key)")
            let translated = Self.forms(of: Self.localization(language, of: entry)).first?.text
            #expect(translated?.isEmpty == false, "no \(language) for \(key) in \(folder)")
        }
    }

    @Test("every Siri phrase is translated, naming the app once", arguments: Self.translations)
    func siriPhrasesAreTranslated(language: String) throws {
        let source = try String(
            contentsOf: Self.sourceRoot.appending(path: "OpenHikes/Intents/OpenHikesShortcuts.swift"),
            encoding: .utf8
        )
        let phrases = Set(
            source.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .flatMap { $0.matches(of: #/"([^"]*\\\(\.applicationName\)[^"]*)"/#) }
                .map { Self.catalogSpelling(of: String($0.1)) }
        )
        try #require(phrases.count >= 10, "no phrases read out of OpenHikesShortcuts.swift")
        var listed: Set<String> = []
        for (key, value) in try Self.catalog(in: "OpenHikes", table: "AppShortcuts") {
            let entry = value as? [String: Any] ?? [:]
            let englishPhrases = Self.phrases(in: Self.localization("en", of: entry))
            let english = englishPhrases.isEmpty ? [key] : englishPhrases
            let translated = Self.phrases(in: Self.localization(language, of: entry))
            listed.formUnion(english)
            #expect(!translated.isEmpty, "no \(language) Siri phrases for \(key)")
            let parameters = Set(english.flatMap(Self.parameters(of:)))
            for phrase in translated {
                let names = phrase.components(separatedBy: "${applicationName}").count - 1
                #expect(names == 1, "\(phrase) names the app \(names) times")
                let ownParameters = Set(Self.parameters(of: phrase)).subtracting(parameters)
                #expect(ownParameters.isEmpty, "\(phrase) asks for \(ownParameters.sorted()), its English doesn't")
            }
        }
        let differences = listed.symmetricDifference(phrases).sorted()
        #expect(differences.isEmpty, "AppShortcuts.xcstrings and OpenHikesShortcuts.swift differ on: \(differences)")
    }

    /// A hike's stat row and the widget's figure count the same points, under
    /// two spellings of the English, so no key holds them to one word.
    @Test("the app and the widget name a track point alike", arguments: Self.translations)
    func trackPointsKeepOneName(language: String) throws {
        let app = try #require(Self.catalog(in: "OpenHikes")["Track Points"] as? [String: Any])
        let widget = try #require(Self.catalog(in: "OpenWidget")["Track points"] as? [String: Any])
        let names = [app, widget].map { Self.forms(of: Self.localization(language, of: $0)).first?.text.lowercased() }
        #expect(names[0] != nil && names[0] == names[1], "\(language) names a track point \(names)")
    }

    /// The `language` localization of a catalog entry, empty when it has none.
    static func localization(_ language: String, of entry: [String: Any]) -> [String: Any] {
        (entry["localizations"] as? [String: Any])?[language] as? [String: Any] ?? [:]
    }

    /// The keys of `strings` a translator has words in that have no
    /// `language` localization.
    static func untranslated(into language: String, in strings: [String: Any]) -> [String] {
        strings.compactMap { key, value -> String? in
            guard let entry = value as? [String: Any], needsTranslation(key, entry) else { return nil }
            return localization(language, of: entry).isEmpty ? key : nil
        }
    }

    /// A key a translator has words in: still extracted, not marked for no
    /// translation, and more than placeholders and punctuation.
    static func needsTranslation(_ key: String, _ entry: [String: Any]) -> Bool {
        entry["extractionState"] as? String != "stale"
            && entry["shouldTranslate"] as? Bool != false
            && key.replacing(placeholder, with: "").contains(where: \.isLetter)
    }

    /// The English a translation stands in for: the key itself, except for a
    /// key named for its meaning, such as `walk.percentHiked`, whose English
    /// is the default value the source hands it (*One English word that a
    /// translation splits takes a second key* in the repository instructions).
    static func english(of key: String, _ entry: [String: Any]) -> String {
        guard entry["extractionState"] as? String == "extracted_with_value",
              let unit = localization("en", of: entry)["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String else { return key }
        return value
    }

    /// The strings a localization holds: its one value, or each plural form.
    static func forms(of localization: [String: Any]) -> [(form: String, text: String)] {
        if let unit = localization["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
            return [("other", text)]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.compactMap { form, variation in
            let unit = (variation as? [String: Any])?["stringUnit"] as? [String: Any]
            return (unit?["value"] as? String).map { (form, $0) }
        }
    }

    /// Each placeholder as `position:conversion`, the implicit ones numbered
    /// in order, so "%@ of %@" and "%1$@ of %2$@" read the same.
    static func placeholders(in text: String) -> [String] {
        var position = 0
        return text.matches(of: placeholder).compactMap { match in
            guard let conversion = match.2 else { return nil }
            position += 1
            return "\(match.1.map { String($0) } ?? String(position)):\(conversion)"
        }
    }

    /// The phrases one localization of the App Shortcuts catalog holds: a
    /// set, the way the IDE writes them, or one phrase to a key.
    static func phrases(in localization: [String: Any]) -> [String] {
        if let set = localization["stringSet"] as? [String: Any], let values = set["values"] as? [String] {
            return values
        }
        return forms(of: localization).map(\.text)
    }

    /// The parameters a Siri phrase asks for, the app's name aside.
    static func parameters(of phrase: String) -> [String] {
        phrase.matches(of: #/\$\{(\w+)\}/#).map { String($0.1) }.filter { $0 != "applicationName" }
    }

    /// A phrase literal as the catalog spells it: `\(.applicationName)` as
    /// `${applicationName}`, and a parameter `\(\.$hike)` as `${hike}`.
    static func catalogSpelling(of literal: String) -> String {
        literal.replacing(#/\\\(\\?\.\$?(\w+)\)/#) { "${\($0.1)}" }
    }

    /// A format specifier, or the `%%` that is not one.
    private static var placeholder: Regex<(Substring, Substring?, Substring?)> {
        #/%(?:(\d+)\$)?(@|lld|ld|d|f)|%%/#
    }
}
