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
    /// The bundled Stadia Maps API key, or `nil` if none is configured.
    /// The in-app Settings key (if the user entered one) takes precedence over this.
    static let stadiaAPIKey: String? = value(for: "StadiaAPIKey")

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
