//
//  PhotoUITests+Toolbar.swift
//  OpenHikesUITests
//
//  How the gallery's three buttons are arranged, which is an argument rather
//  than a layout.
//
//  *Show where this was taken* and *Share* both take the photograph somewhere
//  and neither destroys it, so they sit together in one glass capsule. *Delete*
//  is on the far side of a ``GlassToolbarSpacer``, because a capsule drawn
//  around all three would put the destructive one a fingertip from the harmless
//  ones with no edge between them.
//
//  Asserted as an order of frames rather than by reading the capsules, which
//  XCUI cannot see: what the arrangement has to guarantee is that the trash is
//  not adjacent to the two, and adjacency is a position.
//

import XCTest

extension PhotoUITests {
    @MainActor
    func assertGalleryToolbarArrangement(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let share = element("photo-share-button", in: app)
        let onMap = element("photo-show-on-map-button", in: app)
        let delete = element("photo-delete-button", in: app)

        XCTAssertTrue(
            share.waitForExistence(timeout: UITestTimeout.existence),
            "the gallery should offer to share the photograph it is showing",
            file: file,
            line: line
        )
        XCTAssertTrue(
            onMap.exists,
            "an anchored photograph should offer to show where it was taken",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            onMap.frame.minX,
            share.frame.minX,
            "share should sit beside the map button rather than across the spacer",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            share.frame.maxX,
            delete.frame.minX,
            "the destructive button should stay on the far side of both",
            file: file,
            line: line
        )
    }
}
