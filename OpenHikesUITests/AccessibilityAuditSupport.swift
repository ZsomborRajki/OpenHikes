//
//  AccessibilityAuditSupport.swift
//  OpenHikesUITests
//
//  The `performAccessibilityAudit` plumbing, and the argument for every issue
//  it is told to ignore.
//
//  Shared rather than private to one class because the sweep is run per screen
//  — the audit only ever sees what is on screen at the time — and those
//  screens are spread across more than one suite. Kept out of
//  `UITestSupport.swift` because the exclusions below are a long argument in
//  their own right, and burying them among launch helpers is how one of them
//  would come to be widened without one.
//

import XCTest

/// The sweep's configuration and its filters, as a namespace rather than a
/// base class: a suite reaches them through `audit(_:for:file:line:)` below,
/// and nothing here needs an instance.
nonisolated enum AccessibilityAudit {
    /// Three audits are excluded, all because they report things this app does
    /// not own.
    ///
    /// - `.contrast` reads rendered pixels, and every sheet control here sits
    ///   on a live glass background over an arbitrary map — the measured ratio
    ///   is whatever tiles happen to be underneath.
    /// - `.textClipped` measures MapKit's own attribution and scale views.
    /// - `.dynamicType` reports SwiftUI nodes whose font it cannot introspect,
    ///   including a navigation bar's system "Done" button and `Form` section
    ///   footers — text this app neither styles nor sizes. Every font it does
    ///   set is a semantic one, which scales by definition; the only fixed
    ///   sizes are decorative glyphs inside fixed frames, already hidden from
    ///   VoiceOver. ``StatGrid`` covers the case that actually mattered.
    static let types: XCUIAccessibilityAuditType = .all
        .subtracting(.contrast)
        .subtracting(.textClipped)
        .subtracting(.dynamicType)

    static let systemOwnedIdentifiers: Set<String> = [
        "trail-map",
    ]

    /// Enough to find the view again — the compact description alone names the
    /// problem but not the control.
    ///
    /// The fallbacks matter as much as the identifier does. An issue the audit
    /// cannot attribute to any element used to report as "an unidentifiable
    /// element" and nothing else, which named neither the view nor the screen
    /// region and left the only way forward a guess; the type and the frame
    /// are what turn that back into something locatable.
    @MainActor
    static func report(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element
        let parts = [
            element?.identifier,
            element?.label,
            element?.value as? String,
        ].compactMap { part in
            (part?.isEmpty == false) ? part : nil
        }
        let subject = parts.isEmpty
            ? (element?.elementType).map { "element type \($0.rawValue)" }
                ?? "an unidentifiable element"
            : parts.joined(separator: " / ")
        let frame = element.map { "\n Frame: \($0.frame)" } ?? ""
        return """
            \(issue.compactDescription)
            \(issue.detailedDescription)
            Element: \(subject)\(frame)
            """
    }

    /// Issues raised against views the app does not build. MapKit draws its own
    /// compass, scale, attribution label and annotation views inside
    /// ``MapView``, and their sizes and labels are not ours to set.
    ///
    /// The audit names the offending view's class in its detailed description,
    /// which is the only handle an out-of-process test has on it: those views
    /// carry no identifier, and the map itself is the only element of ours they
    /// can be attributed to.
    ///
    /// The third clause covers the map's *tiles* rather than its subviews.
    /// Element detection reads rendered pixels, and an OpenStreetMap raster
    /// tile has town and road names drawn into it — text with no element
    /// behind it anywhere, because it is a picture of text. While the map is
    /// the front screen those issues are attributed to `trail-map` and the
    /// first clause catches them. Behind a presented sheet it is not in the
    /// accessibility tree at all, so the audit reports them with no element to
    /// attribute them to, and they arrive here as an unnamed "potentially
    /// inaccessible text".
    ///
    /// That combination — element detection, and no element at all — is only
    /// reachable for something outside the tree, which the app's own frontmost
    /// content never is. It stays narrow for that reason: a `Text` this app
    /// forgot to expose is still attributed to the SwiftUI element that drew
    /// it and is still reported.
    ///
    /// This is the same argument `.contrast` is excluded wholesale under —
    /// both read pixels, and the pixels behind this app's sheets are an
    /// arbitrary map.
    @MainActor
    static func isSystemOwned(
        _ issue: XCUIAccessibilityAuditIssue
    ) -> Bool {
        if let identifier = issue.element?.identifier,
           Self.systemOwnedIdentifiers.contains(identifier) {
            return true
        }
        if issue.auditType == .elementDetection, issue.element == nil {
            return true
        }
        return issue.detailedDescription
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0.hasPrefix("MK") }
    }
}

extension XCTestCase {
    /// Runs the sweep and reports every issue at once, rather than failing on
    /// the first.
    @MainActor
    func audit(
        _ app: XCUIApplication,
        for types: XCUIAccessibilityAuditType = AccessibilityAudit.types,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var reports: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            if !AccessibilityAudit.isSystemOwned(issue) {
                reports.append(AccessibilityAudit.report(issue))
            }
            // Always "handled": an issue is either collected above or
            // deliberately ignored, and reporting them together beats failing
            // on whichever the sweep happened to reach first.
            return true
        }
        guard reports.isEmpty else {
            XCTFail(
                "\(reports.count) accessibility issue(s):\n"
                    + reports.joined(separator: "\n\n"),
                file: file,
                line: line
            )
            return
        }
    }

    @MainActor
    func openSettings(in app: XCUIApplication) {
        let settings = element("settings-button", in: app)
        XCTAssertTrue(
            settings.waitForExistence(timeout: UITestTimeout.existence)
        )
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
    }

    @MainActor
    func waitUntilValueChanges(
        from original: String,
        in element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String != original { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
