//
//  MapSheetPresenter.swift
//  OpenHikes
//
//  Where the map screen's sheet is presented, and kept up.
//
//  A `ViewModifier` of its own for the one read it makes:
//  ``SheetPresentation/isSheetPresented``. A modifier is a render boundary for
//  the reads in its own `body(content:)`, so a write to the flag re-runs this
//  and not `OpenHikesView`, whose body is the whole map screen. That flag was
//  `@State` on the root view, and moving it here is what lets the sheet wait
//  for the window's shape at no cost to the launch that needs no waiting: a
//  phone held upright raises it on the layout reader's first report, and the
//  root view hears nothing of it. See *Render isolation, in practice* in the
//  repository instructions.
//
//  Its arguments are still evaluated in the body that applies it, so the
//  sheet's contents are built there exactly as they were when the `.sheet`
//  was written out in that body.
//

import SwiftUI

extension View {
    /// Presents `content` as the map screen's sheet whenever
    /// ``SheetPresentation/isSheetPresented`` says so, and puts it back up if
    /// something takes it down while the window still wants a sheet.
    func presentsMapSheet(
        _ presentation: SheetPresentation,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(MapSheetPresenter(presentation: presentation, sheetContent: content))
    }
}

private struct MapSheetPresenter<SheetContent: View>: ViewModifier {
    let presentation: SheetPresentation
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Bindable(presentation).isSheetPresented, content: sheetContent)
            // The sheet is the app's primary surface in a narrow window and
            // must always stay up there. The GPX document picker (a UIKit
            // controller presented from within a detented sheet) tears the
            // sheet down on dismissal — a known SwiftUI issue — so if it ever
            // goes away, bring it right back. The side panel is the one
            // dismissal that is meant, and the layout is what tells the two
            // apart. Read here, in the action, so it is no input of this body.
            .onChange(of: presentation.isSheetPresented) { _, shown in
                if !shown, presentation.layout == .bottomSheet {
                    presentation.isSheetPresented = true
                }
            }
            // A rotation, or an iPhone Duo opening, takes the sheet down and
            // puts it back up: in a wide window the contents are in
            // ``MapSidePanel`` and there is no sheet.
            //
            // In a change handler, so one update *after* the one that drew the
            // new shape, and never in the same write as the layout. A card
            // open over the contents — *Places Around Trail*'s, *Places
            // Nearby*'s, a walk's share card — moves to the panel's copy of
            // them only if that copy is built before the sheet goes. Taken
            // down in the same update, the card went with the sheet, and four
            // of `OrientationUITests`' and `MapModesUITests`' rotations failed
            // on it.
            .onChange(of: presentation.layout) { _, layout in
                presentation.isSheetPresented = layout == .bottomSheet
            }
    }
}
