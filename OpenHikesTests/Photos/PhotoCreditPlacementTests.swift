//
//  PhotoCreditPlacementTests.swift
//  OpenHikesTests
//
//  Where a full-size photograph's credit stands: under the picture where the
//  black a photograph leaves is above and below it, and at the leading edge
//  where it is either side — see ``PhotoGalleryControls``. The sizes are the
//  frames the galleries' controls are laid out in on an iPhone 18 Pro, inside
//  the safe area and under the navigation bar.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Photo credit placement")
struct PhotoCreditPlacementTests {
    @Test("upright, the credit goes under the picture")
    func portrait() {
        #expect(PhotoCreditPlacement(for: CGSize(width: 402, height: 720)) == .underneath)
    }

    @Test("turned on its side, it goes beside the picture")
    func landscape() {
        #expect(PhotoCreditPlacement(for: CGSize(width: 750, height: 337)) == .beside)
    }

    /// The hiker's own gallery after *Show on Map* in landscape: the side
    /// panel's column beside the map, where a photograph is letterboxed
    /// again and a credit beside the pill would run into it.
    @Test("in the side panel's column, it goes under the picture again")
    func sidePanelColumn() {
        #expect(PhotoCreditPlacement(for: CGSize(width: 320, height: 337)) == .underneath)
    }

    /// A 3:2 photograph fills a 3:2 frame and leaves no black either side.
    @Test("a frame no wider than a camera's photograph keeps it under the picture")
    func ordinaryShape() {
        #expect(PhotoCreditPlacement(for: CGSize(width: 900, height: 600)) == .underneath)
        #expect(PhotoCreditPlacement(for: CGSize(width: 901, height: 600)) == .beside)
    }
}
