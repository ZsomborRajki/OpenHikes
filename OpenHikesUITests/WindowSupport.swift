//
//  WindowSupport.swift
//  OpenHikesUITests
//
//  Where the app's window is, and whether XCUITest's hit test can be believed
//  in it, for every class in this bundle. Both have one answer on every iPhone
//  and another on the iPhone Duo's inner display turned to landscape, which is
//  the way up that display opens.
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
    /// turned back to portrait.
    ///
    /// There XCUITest answered *not hittable* for every element in the side
    /// panel — the hike screen's Back button among them, in plain sight at
    /// the panel's top — while the map's own buttons beside the panel
    /// answered yes. The screenshot set's scrolls swiped *Find Photos* up
    /// past the panel's header and back again for want of a yes. Taps and
    /// drags are aimed at frames, which are measured in the turned window,
    /// and they land. On the same display upright, and on any other iPhone in
    /// landscape, `app.frame` turns with the window and this is false.
    @MainActor
    func hitTestIsUnreliable(in app: XCUIApplication, window: CGRect) -> Bool {
        let stale = app.frame
        return window.width > window.height
            && abs(stale.width - window.height) < 1
            && abs(stale.height - window.width) < 1
    }
}
