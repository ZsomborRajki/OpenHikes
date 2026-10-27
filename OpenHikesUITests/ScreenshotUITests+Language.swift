//
//  ScreenshotUITests+Language.swift
//  OpenHikesUITests
//
//  A capture uses the app's compiled translations for its lookups. The
//  script passes that catalog to the runner, so German is never a second
//  handwritten copy of the shipping UI in this target.
//

import Foundation
import UIKit
import XCTest

extension ScreenshotUITests {
    private static let screenshotStrings: [String: String] = {
        let encoded = ProcessInfo.processInfo.environment["OPENHIKES_SCREENSHOT_STRINGS"] ?? "{}"
        return (try? JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))) ?? [:]
    }()

    static var screenshotIsGerman: Bool {
        let locale = ProcessInfo.processInfo.environment["OPENHIKES_SCREENSHOT_LOCALE"] ?? "en_IE"
        return Locale(identifier: locale).language.languageCode?.identifier == "de"
    }

    func screenshotText(_ key: String) -> String {
        Self.screenshotStrings[key] ?? key
    }

    /// UIKit gives its sheet handle a localized label and no identifier.
    /// Read that label from UIKit's accessibility bundle for the capture's
    /// language, rather than copying its translations into these tests.
    @MainActor
    func screenshotSheetGrabber(in app: XCUIApplication) -> XCUIElement {
        let language = Self.screenshotIsGerman ? "de" : "en"
        let resources = Bundle(for: UIView.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AccessibilityBundles/UIKit.axbundle/\(language).lproj")
        let label = Bundle(url: resources)?.localizedString(
            forKey: "sheet.grabber", value: "Sheet Grabber", table: "Accessibility"
        ) ?? "Sheet Grabber"
        return app.buttons[label]
    }
}
