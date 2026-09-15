//
//  CommunityUITests+ShareForm.swift
//  OpenHikesUITests
//
//  The share form's two new gestures, which did not fit in the class they
//  belong to: correcting the hike's name, and leaving a photograph out.
//
//  Not a second test class — SwiftLint's `single_test_class` forbids that, and
//  a new class would also have to be added to the list of functional classes
//  `Scripts/run-ui-tests.sh` names. An extension keeps both facts unchanged:
//  these are `CommunityUITests` methods, and `--suite CommunityUITests` still
//  selects them.
//
//  Both drive the form and then assert somewhere else — the detail screen's
//  title, the hike's own gallery — because what #389 asked for is that these
//  edits belong to the *hike* rather than to the copy that goes public. An
//  assertion read back out of the field it was typed into would prove only
//  that the keyboard works.
//

import XCTest

extension CommunityUITests {
    /// Where to tap a text field to put the caret after the text already in
    /// it: at the trailing edge rather than the middle, which is where a plain
    /// `tap()` lands.
    private static let fieldTrailingFraction = 0.95
    private static let fieldMiddleFraction = 0.5
    private static let trailingEdgeOfAField = CGVector(
        dx: fieldTrailingFraction,
        dy: fieldMiddleFraction
    )

    /// Renaming a hike from the share form, which renames the hike.
    ///
    /// The point of the field is that a hiker about to publish "Morning walk"
    /// is the likeliest person to want it fixed — and #389 asked for the fix
    /// to be theirs to keep, not just the strangers'. So the assertion is made
    /// on the detail screen *after cancelling*: what has to be true is that the
    /// hike was renamed, and that it was renamed whether or not the share
    /// went ahead.
    @MainActor
    func testRenamingOnTheShareFormRenamesTheHike() {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)
        let renamed = "Thumsee, the long way round"

        tapWhenReady(element("community-share-button", in: app))
        let field = element("community-share-title", in: app)
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.existence),
            "the share sheet should offer the hike's name for correction"
        )
        XCTAssertEqual(
            field.value as? String,
            UITestFixture.importedHikeTitle,
            "the field should open on what the hike is already called"
        )
        // Tapped at the trailing edge rather than in the middle. A tap puts
        // the caret where it landed, and this field opens already full — so a
        // centre tap drops the caret into the middle of the existing name and
        // the deletes below eat half of it, leaving a title that is neither
        // the old one nor the new one.
        field.coordinate(withNormalizedOffset: Self.trailingEdgeOfAField).tap()
        // A character at a time, the way `CommunityReviewUITests` clears the
        // reviewer's copy of this field: what somebody does to a bad title is
        // replace it, and a long press racing a callout menu is a flake this
        // assertion does not need.
        field.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: UITestFixture.importedHikeTitle.count
            )
        )
        field.typeText(renamed)
        // Asserted before leaving, so a failure below says which half broke:
        // the typing, or the commit that is supposed to carry it to the hike.
        XCTAssertEqual(
            field.value as? String,
            renamed,
            "the field should hold the replacement before the sheet is dismissed"
        )
        // Cancelled rather than shared, for the reason the notes test cancels:
        // the name belongs to the walk, so thinking better of publishing must
        // not throw away the correction.
        app.buttons["Cancel"].firstMatch.tap()

        XCTAssertTrue(
            app.navigationBars[renamed].waitForExistence(timeout: UITestTimeout.navigation),
            "the hike's own screen should show the name typed on the share form"
        )
    }

    /// Leaving a photograph out of a share without deleting it from the hike.
    ///
    /// The count row is what the test watches rather than the tile's
    /// appearance: striking one off is drawn as a glyph and an opacity, and
    /// what actually matters is the number that will be uploaded — which is
    /// re-asked of the disk each time, because the cap means taking one out
    /// can let another in.
    @MainActor
    func testStrikingAPhotoOffTheShareFormLeavesItBehind() {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: [
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
            ]
        )
        openHikeDetail(in: app)

        tapWhenReady(element("community-share-button", in: app))
        let count = element("community-share-photo-count", in: app)
        XCTAssertTrue(
            count.waitForExistence(timeout: UITestTimeout.existence),
            "the share sheet should say how many photographs go"
        )
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { count.value as? String == "2" },
            "both seeded photographs should start out included"
        )

        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "community-share-photo-tile-"))
            .firstMatch
        tapWhenReady(tile)

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { count.value as? String == "1" },
            "striking one off should take it out of what gets shared"
        )

        // And it is still the hike's photograph: leaving one out of a share is
        // not a deletion, which is the whole difference #389 asked for.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            photoTile(at: 2, of: 2, in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the hike should still have both pictures in its own gallery"
        )
    }
}
