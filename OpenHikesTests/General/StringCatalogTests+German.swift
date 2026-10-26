//
//  StringCatalogTests+German.swift
//  OpenHikesTests
//
//  German, read out of the source tree like the rest of this suite. A key
//  with no German falls back to English without a word, and a German value
//  that drops or retypes a placeholder formats the wrong argument. Neither
//  shows anywhere else, because the hosted tests run in English.
//
//  The Info.plist and App Shortcuts catalogs have no sync to keep them
//  current: the IDE extracts into them, `xcodebuild` does not, and
//  `Scripts/sync-string-catalogs.sh` covers the `Localizable` tables only.
//  So the last two tests hold each one to what it translates, and a
//  permission prompt or a Siri phrase edited without its catalog fails here.
//

import Foundation
import Testing

extension StringCatalogTests {
    @Test("every catalogued string has German", arguments: Self.catalogFolders)
    func everyStringHasGerman(folder: String) throws {
        let missing = try Self.untranslated(in: Self.catalog(in: folder))
        #expect(missing.isEmpty, "no German in \(folder) for: \(missing.sorted())")
    }

    /// An Info.plist catalog holds more than the prompts checked below: the
    /// IDE extracts the bundle's name into it, and the name Files shows for a
    /// GPX file. Each needs German, or to be marked as not translated.
    @Test("every Info.plist string has German", arguments: ["OpenHikes", "OpenHikesWatch"])
    func everyInfoPlistStringHasGerman(folder: String) throws {
        let missing = try Self.untranslated(in: Self.catalog(in: folder, table: "InfoPlist"))
        #expect(missing.isEmpty, "no German in \(folder)/InfoPlist.xcstrings for: \(missing.sorted())")
    }

    @Test("German keeps the placeholders its English is handed", arguments: Self.catalogFolders)
    func germanKeepsThePlaceholders(folder: String) throws {
        var offenders: [String] = []
        for (key, value) in try Self.catalog(in: folder) {
            let entry = value as? [String: Any] ?? [:]
            let german = Self.localization("de", of: entry)
            if german.isEmpty { continue }
            let english = Self.placeholders(in: key)
            let forms = Self.forms(of: german)
            let isPlural = Self.localization("en", of: entry)["variations"] != nil
            if forms.isEmpty || (isPlural && german["variations"] == nil) {
                offenders.append(key)
            }
            for (form, text) in forms {
                let found = Self.placeholders(in: text)
                // A singular may leave the count out, as "One photo goes on %2$@" does.
                let fits = form == "one" ? Set(found).isSubset(of: english) : found.sorted() == english.sorted()
                if !fits { offenders.append("\(key) → \(text)") }
            }
        }
        #expect(offenders.isEmpty, "German in \(folder) its English cannot fill: \(offenders.sorted())")
    }

    @Test("every permission prompt has German, for the English its Info.plist has", arguments: [
        "OpenHikes", "OpenHikesWatch",
    ])
    func permissionPromptsHaveGerman(folder: String) throws {
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
            let german = Self.forms(of: Self.localization("de", of: entry)).first?.text
            #expect(german?.isEmpty == false, "no German for \(key) in \(folder)")
        }
    }

    @Test("every Siri phrase has German that names the app once")
    func siriPhrasesHaveGerman() throws {
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
            let german = Self.phrases(in: Self.localization("de", of: entry))
            listed.formUnion(english)
            #expect(!german.isEmpty, "no German Siri phrases for \(key)")
            let parameters = Set(english.flatMap(Self.parameters(of:)))
            for phrase in german {
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

    /// The keys of `strings` a translator has words in that have no German.
    static func untranslated(in strings: [String: Any]) -> [String] {
        strings.compactMap { key, value -> String? in
            guard let entry = value as? [String: Any], needsTranslation(key, entry) else { return nil }
            return localization("de", of: entry).isEmpty ? key : nil
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
