//
//  ScreenshotUITests+Language.swift
//  OpenHikesUITests
//
//  A capture uses the app's compiled translations for its lookups. The
//  script passes that catalog to the runner, so German is never a second
//  handwritten copy of the shipping UI in this target.
//

import Foundation
import MapKit
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
        app.buttons[screenshotSystemText("sheet.grabber", bundle: "UIKit", framework: UIView.self)]
    }

    @MainActor
    func screenshotCompass(in app: XCUIApplication) -> XCUIElement {
        app.buttons[screenshotSystemText("COMPASS_BUTTON", bundle: "MapKitFramework", framework: MKMapView.self)]
    }

    /// MapKit's animated location puck is a map annotation, including on the
    /// Duo where hit testing cannot tell us whether its display is visible.
    @MainActor
    func screenshotUserLocation(in app: XCUIApplication) -> XCUIElement {
        let language = Self.screenshotIsGerman ? "de" : "en"
        let resources = Bundle(for: MKMapView.self).bundleURL.appendingPathComponent("\(language).lproj")
        let label = Bundle(url: resources)?.localizedString(forKey: "My Location", value: nil, table: "Localizable")
        XCTAssertNotNil(label, "MapKit should supply its location annotation label")
        return app.otherElements.matching(NSPredicate(format: "label == %@", label ?? "My Location")).firstMatch
    }

    @MainActor
    private func screenshotSystemText(_ key: String, bundle: String, framework: AnyClass) -> String {
        let language = Self.screenshotIsGerman ? "de" : "en"
        let resources = Bundle(for: framework).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AccessibilityBundles/\(bundle).axbundle/\(language).lproj")
        let label = Bundle(url: resources)?.localizedString(forKey: key, value: nil, table: "Accessibility")
        XCTAssertNotNil(label, "the system accessibility bundle should supply \(key) in \(language)")
        XCTAssertNotEqual(label, key, "the system accessibility key should have a translation")
        return label ?? key
    }
}
