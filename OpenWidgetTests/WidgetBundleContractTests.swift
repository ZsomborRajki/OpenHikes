//
//  WidgetBundleContractTests.swift
//  OpenWidgetTests
//
//  The widget's own silent key.
//
//  `NSWidgetWantsLocation` is what tells WidgetKit this widget's timeline
//  depends on where the phone is. Without it the widget still builds, still
//  installs and still draws — it simply never receives a location, so the
//  sparse anchors stop and the GPS-gap repair that reads them stops with them.
//  No error, no log, nothing on screen: the widget looks like one that was
//  written without the feature.
//
//  Nothing in Swift refers to it, so this is the only place it can be held —
//  the widget half of `InfoPlistContractTests` in the app bundle, and there
//  for the same reasons.
//
//  ## Which copy this reads
//
//  This bundle is hosted by OpenHikes.app, so `Bundle.main` here is the *app*.
//  The widget's plist is the one inside the embedded `.appex`, reached through
//  the host's plug-ins directory — which is the copy that actually ships, the
//  same principle `PrivacyManifestTests` reads the manifest by. A test that
//  read `OpenWidget/Info.plist` out of the repository would pass while the
//  build embedded something else entirely.
//

import Foundation
import Testing

@Suite("Widget bundle contract")
struct WidgetBundleContractTests {
    /// The embedded widget extension's `Info.plist`, as built.
    ///
    /// Found by extension rather than by name so a target rename does not
    /// silently turn every assertion below into a skip — and the count is
    /// asserted, so an extension that failed to embed fails here rather than
    /// disappearing.
    private func widgetInfo() throws -> [String: Any] {
        let plugIns = try #require(
            Bundle.main.builtInPlugInsURL,
            "the host app bundle has no plug-ins directory"
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: plugIns,
            includingPropertiesForKeys: nil
        )
        let extensions = contents.filter { $0.pathExtension == "appex" }
        #expect(extensions.count == 1, "expected exactly one embedded extension")
        let appex = try #require(extensions.first, "no widget extension is embedded in the app")
        let data = try Data(contentsOf: appex.appending(path: "Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    /// The key the whole location-aware half of the widget depends on.
    @Test("the widget declares that it wants location")
    func wantsLocation() throws {
        #expect(try widgetInfo()["NSWidgetWantsLocation"] as? Bool == true)
    }

    /// The extension point itself. A widget whose `NSExtension` dictionary
    /// names anything else is not a widget, and the failure is the same shape:
    /// it builds, it embeds, and it never appears in the gallery.
    @Test("the extension is declared as a WidgetKit extension")
    func isAWidgetKitExtension() throws {
        let extensionInfo = try #require(
            widgetInfo()["NSExtension"] as? [String: Any],
            "the widget extension declares no NSExtension dictionary"
        )
        #expect(
            extensionInfo["NSExtensionPointIdentifier"] as? String
                == "com.apple.widgetkit-extension"
        )
    }

    /// Declared on the extension as well as on the app: App Store Connect asks
    /// the export-compliance question per uploaded binary, and an embedded
    /// extension missing it prompts on every upload.
    @Test("the export compliance answer is declared on the extension too")
    func exportComplianceIsDeclared() throws {
        #expect(try widgetInfo()["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }
}
