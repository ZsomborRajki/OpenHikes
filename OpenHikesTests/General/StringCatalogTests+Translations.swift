//
//  StringCatalogTests+Translations.swift
//  OpenHikesTests
//
//  The translations, German and French, read out of the source tree like the
//  rest of this suite. A key with no translation falls back to English
//  without a word, and a translated value that drops or retypes a
//  placeholder formats the wrong argument. Neither shows anywhere else,
//  because the hosted tests run in English.
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
    nonisolated static let translations = ["de", "fr"]

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
            let english = Self.placeholders(in: key)
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
    /// one goes. Its singular keeps the number.
    @Test("a French singular keeps its count, because French reads zero as one", arguments: Self.catalogFolders)
    func frenchSingularKeepsTheCount(folder: String) throws {
        var offenders: [String] = []
        for (key, value) in try Self.catalog(in: folder) {
            let entry = value as? [String: Any] ?? [:]
            let french = Self.localization("fr", of: entry)
            guard french["variations"] != nil else { continue }
            let counts = Set(Self.placeholders(in: key).filter { !$0.hasSuffix(":@") && !$0.hasSuffix(":f") })
            for (form, text) in Self.forms(of: french) where form == "one" {
                if !counts.isSubset(of: Set(Self.placeholders(in: text))) {
                    offenders.append("\(key) → \(text)")
                }
            }
        }
        #expect(offenders.isEmpty, "French singulars in \(folder) that drop their count: \(offenders.sorted())")
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
