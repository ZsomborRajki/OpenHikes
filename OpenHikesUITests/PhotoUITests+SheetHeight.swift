//
//  PhotoUITests+SheetHeight.swift
//  OpenHikesUITests
//
//  Where the sheet is, for the tests that care.
//
//  A detent is not something XCUITest can read, so both waits below are frames:
//  the sheet's top edge as a share of the screen. Split out of `PhotoUITests`
//  for the reason `CommunityUITests+ShareForm.swift` was — an `extension` keeps
//  these methods `PhotoUITests` members, so `--suite PhotoUITests` still selects
//  everything, rather than a second class `single_test_class` forbids.
//
//  Two waits rather than one, and the difference is the point. One test drags
//  the sheet to the bottom itself and asserts that it went; the photo-on-map
//  tests assert where the *app* puts it, which is its middle detent — the
//  height every camera move frames against. See
//  `MapCoordinator+RouteFitting.swift`.
//

import XCTest

extension PhotoUITests {
    /// Waits for the sheet to be sitting at its lowest detent.
    ///
    /// The compact height is a small fraction of the screen, so a sheet whose
    /// top edge is down in the bottom fifth is at it and a sheet at any other
    /// detent is not.
    @MainActor
    func waitForCollapsedSheet(in app: XCUIApplication) -> Bool {
        let sheet = element("map-sheet", in: app)
        guard sheet.waitForExistence(timeout: UITestTimeout.navigation) else {
            return false
        }
        let collapsed = NSPredicate { _, _ in
            sheet.frame.minY > app.frame.height * Self.collapsedSheetFraction
        }
        let settled = expectation(for: collapsed, evaluatedWith: sheet)
        return XCTWaiter.wait(
            for: [settled],
            timeout: UITestTimeout.navigation
        ) == .completed
    }

    /// Waits for the sheet to come to rest at its middle detent.
    ///
    /// What "show this photo on the map" now leaves behind. It used to collapse
    /// the sheet outright, which was the only way to keep the pin visible while
    /// a camera move framed into the whole window; the map frames into the part
    /// of itself the sheet is not over now, so the two meet instead of one
    /// getting out of the other's way.
    @MainActor
    func waitForSheetAtMiddleDetent(in app: XCUIApplication) -> Bool {
        let sheet = element("map-sheet", in: app)
        guard sheet.waitForExistence(timeout: UITestTimeout.navigation) else {
            return false
        }
        let settledAtMiddle = NSPredicate { _, _ in
            let top = sheet.frame.minY
            return top > app.frame.height * Self.middleSheetLowerBound
                && top < app.frame.height * Self.middleSheetUpperBound
        }
        let settled = expectation(for: settledAtMiddle, evaluatedWith: sheet)
        return XCTWaiter.wait(
            for: [settled],
            timeout: UITestTimeout.navigation
        ) == .completed
    }

    /// How far down the screen the collapsed sheet's top edge has to be.
    ///
    /// The compact detent is 80 points tall against a screen of over 800, so
    /// anything below four fifths is unambiguously it while leaving room for
    /// the home indicator and for a taller device.
    static let collapsedSheetFraction: CGFloat = 0.8

    /// Where the sheet's top edge has to land for it to be at the middle
    /// detent, as a share of the screen.
    ///
    /// A window rather than a number because there is no fraction that *is* the
    /// middle detent: the system rests it 43% of the way down one phone and 48%
    /// down another, which is why `SheetMetrics` learns the figure by watching
    /// rather than computing it. These bounds are wide enough for every device
    /// and narrow enough to exclude the two heights this has to tell it apart
    /// from — `.large`, whose top is near zero, and the compact detent, whose
    /// top is near the bottom of the screen.
    static let middleSheetLowerBound: CGFloat = 0.3
    static let middleSheetUpperBound: CGFloat = 0.65
}
