//
//  WindowSupport.swift
//  OpenHikesUITests
//
//  Where the app's window is, whether XCUITest's hit test can be believed in
//  it, and when it has finished turning, for every class in this bundle. The
//  first two have one answer on every iPhone and another on the iPhone Duo's
//  inner display turned to landscape, which is the way up that display opens.
//

import XCTest

extension XCTestCase {
    /// The app's window, in the space every element's frame is measured in.
    ///
    /// Not `app.frame`. On the iPhone Duo's inner display turned to landscape
    /// that keeps the display's portrait size, 669 × 951, while the window and
    /// everything in it measure 951 × 669 — so a point tested against it is
    /// tested against the wrong shape. Everywhere else the two are the same
    /// rectangle. `app.frame` stands in only before there is a window.
    @MainActor
    func windowFrame(of app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        return window.exists ? window.frame : app.frame
    }

    /// Whether `isHittable` is wrong in `window`: on the iPhone Duo's inner
    /// display turned to landscape, where `app.frame` is the window's size
    /// turned back to portrait, and on an iPad either way up.
    ///
    /// There XCUITest answered *not hittable* for every element in the side
    /// panel — the hike screen's Back button among them, in plain sight at
    /// the panel's top — while the map's own buttons beside the panel
    /// answered yes. The screenshot set's scrolls swiped *Find Photos* up
    /// past the panel's header and back again for want of a yes. Taps and
    /// drags are aimed at frames, which are measured in the turned window,
    /// and they land. On the same display upright, and on any other iPhone in
    /// landscape, `app.frame` turns with the window and this is false.
    ///
    /// An iPad gives the same answers with an `app.frame` that is the window's
    /// own, so it is named rather than measured: a hike row, the Back button
    /// and a photo tile all answered no, and a tap on each landed — on an iPad
    /// Pro 13-inch simulator on iOS 27.2, where the tree lists a `Toolbar` as
    /// tall as the panel over the panel's contents.
    @MainActor
    func hitTestIsUnreliable(in app: XCUIApplication, window: CGRect) -> Bool {
        if UIDevice.current.userInterfaceIdiom == .pad { return true }
        let stale = app.frame
        return window.width > window.height
            && abs(stale.width - window.height) < 1
            && abs(stale.height - window.width) < 1
    }

    // MARK: - Waiting on the rotation

    /// Waits for the window itself to have turned.
    ///
    /// The app's frame is the effect a rotation has — a duration is not, and
    /// the accessibility tree answers with the old geometry until the system
    /// has finished laying out the new one. Here rather than on
    /// `OrientationUITests` because a turn of the phone is also how
    /// `CommunityReviewUITests` holds a review to its route.
    @MainActor
    func waitForLandscape(_ app: XCUIApplication) -> Bool {
        wait(for: app) { $0.width > $0.height }
    }

    @MainActor
    func waitForPortrait(_ app: XCUIApplication) -> Bool {
        wait(for: app) { $0.height > $0.width }
    }

    @MainActor
    private func wait(
        for app: XCUIApplication,
        until isSettled: @escaping (CGRect) -> Bool
    ) -> Bool {
        let turned = NSPredicate { _, _ in isSettled(app.frame) }
        let settled = expectation(for: turned, evaluatedWith: app)
        return XCTWaiter.wait(
            for: [settled],
            timeout: UITestTimeout.navigation
        ) == .completed
    }
}
