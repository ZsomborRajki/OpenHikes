//
//  OrientationUITests+PlaceAdder.swift
//  OpenHikesUITests
//
//  *Add Place*'s form through a turn of the phone: what was typed into it is
//  still there after it, both ways round.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    private static let typedPlaceName = "Lookout"

    /// Turning the phone with *Add Place*'s form up leaves the form as it was.
    ///
    /// The form is drawn in the sheet in portrait and in the side panel in
    /// landscape, so a turn replaces it. While what it held was its own
    /// state, the form came back new: named after its kind again, the
    /// photographs it was holding gone, and a camera it had open closed. The
    /// Simulator has no camera, so this follows the name, which is held
    /// beside the rest; `HikePlaceAdderSessionTests` follows a picture
    /// through the turn.
    @MainActor
    func testPlaceAdderKeepsWhatWasTypedThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: ["--ui-test-import-gpx=\(PlaceFixture.gpxName)"])
        openPlaceAdder(in: app)
        let name = app.textFields["hike-place-adder-name"]
        XCTAssertTrue(replaceText(of: name, with: Self.typedPlaceName), "precondition: a name is typed")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCTAssertTrue(name.waitForExistence(timeout: UITestTimeout.navigation), "the form is still up in landscape")
        XCTAssertEqual(name.value as? String, Self.typedPlaceName, "turning to landscape keeps what was typed")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        XCTAssertTrue(name.waitForExistence(timeout: UITestTimeout.navigation), "and back in portrait")
        XCTAssertEqual(name.value as? String, Self.typedPlaceName, "and turning back does too")
    }
}
