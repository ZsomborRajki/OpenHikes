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

    /// Whether `provider` has everything it needs to load tiles on this build.
    /// False only for a key-gated provider whose key didn't resolve — a build
    /// with no `Secrets.plist`, or one still holding the template's placeholder.
    static func canLoadTiles(_ provider: TileProvider) -> Bool {
        provider.isUsable(withKey: apiKey(for: provider))
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
