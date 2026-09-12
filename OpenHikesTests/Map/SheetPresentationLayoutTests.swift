//
//  SheetPresentationLayoutTests.swift
//  OpenHikesTests
//
//  The sheet's contents are drawn in two shapes — a detented sheet in
//  portrait, ``MapSidePanel`` in landscape — and ``SheetPresentation`` is where
//  the difference is resolved, so the screens inside never have to ask which
//  one they are in.
//
//  What that resolution has to get right is a detent it must keep and a set of
//  answers it must stop giving. A panel is never compact (the hikes list has
//  the height for itself whatever detent the sheet last rested at), always full
//  height, and at no detent at all — but the stored detent survives the visit,
//  because rotating back has to put the sheet where the hiker left it. The
//  bug all of this exists for is in `OrientationUITests`; these are the rules
//  underneath it.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Sheet presentation layout")
struct SheetPresentationLayoutTests {
    @Test("a side panel is never compact, whatever detent the sheet rested at")
    func sidePanelIsNeverCompact() {
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)
        #expect(presentation.isCompact, "precondition: the sheet was at its smallest detent")

        presentation.layout = .sidePanel

        #expect(presentation.isCompact == false)
        #expect(presentation.isFullHeight, "a panel fills its side of the screen")
        #expect(presentation.isAtMiddleDetent == false, "and rests at no detent")
    }

    @Test("rotating back restores the height the sheet was left at")
    func rotatingBackRestoresTheDetent() {
        let presentation = SheetPresentation(detent: .medium)

        presentation.layout = .sidePanel
        presentation.layout = .bottomSheet

        #expect(presentation.detent == .medium)
        #expect(presentation.isAtMiddleDetent)
        #expect(presentation.isFullHeight == false)
    }

    /// The full-height policy goes on working in a panel — a photo opened in
    /// landscape still takes the sheet's height on the way back to portrait —
    /// but none of it is visible while the panel is up.
    @Test("a detent written while the panel is up is kept, not published")
    func detentWrittenInThePanelIsKept() {
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)
        presentation.layout = .sidePanel

        presentation.detent = .medium

        #expect(presentation.isAtMiddleDetent == false, "still no detent to be at")
        #expect(presentation.isFullHeight, "still the whole height")
        presentation.layout = .bottomSheet
        #expect(presentation.isAtMiddleDetent, "and the sheet comes back at the new height")
    }

    @Test("the sheet's own flags are unchanged by a layout it never leaves")
    func bottomSheetFlagsAreUnchanged() {
        let presentation = SheetPresentation(detent: .large)

        #expect(presentation.isFullHeight)
        #expect(presentation.isCompact == false)

        presentation.detent = SheetPresentation.compactDetent

        #expect(presentation.isCompact)
        #expect(presentation.isFullHeight == false)
    }
}
