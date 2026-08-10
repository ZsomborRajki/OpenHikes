//
//  Secrets.swift
//  OpenTrails
//
//  Reads bundled API keys from `Secrets.plist`, a gitignored resource that is
//  copied into the app bundle at build time. A missing file or a leftover
//  placeholder value resolves to `nil`, so a fresh clone (without the plist)
//  still builds and runs — it just falls back to keyless tile providers.
//

import Foundation

enum Secrets {
    /// The bundled key for `provider`, or `nil` for keyless providers or missing keys.
    static func apiKey(for provider: TileProvider) -> String? {
        guard let plistKey = provider.apiKeyPlistKey else { return nil }
        return value(for: plistKey)
    }

    /// Placeholder values from the committed template resolve to `nil`, never to a broken key.
    private static let placeholderPrefix = "YOUR_"

    private static func value(for key: String) -> String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url),
            let value = dict[key] as? String,
            !value.isEmpty,
            !value.hasPrefix(placeholderPrefix)
        else { return nil }
        return value
    }
}
