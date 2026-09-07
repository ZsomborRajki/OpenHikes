//
//  SheetLayoutReader.swift
//  OpenHikes
//
//  Where the vertical size class is read, and the reason it is not read in
//  `OpenHikesView`.
//
//  The app needs one bit from the environment — whether this is a compact
//  height, which on iPhone means landscape and means the sheet has to become
//  ``MapSidePanel``. Reading it in the root view's body is the obvious way and
//  it costs more than it looks: an `@Environment` read makes that body re-run
//  whenever SwiftUI thinks the value *may* have moved, and the scene
//  transitions a backgrounded recording goes through are one of those times.
//  Measured, with the read in `OpenHikesView`: one extra root body pass per
//  scene transition, which `testBackgroundRecordingCostsNothingPerFix` fails on
//  by exactly that one, plus the map update pass and the tile requests that
//  follow it — 250-odd of them in an offline browse that is budgeted for none.
//  The whole of it went away when the read moved here.
//
//  A `View` of its own because that is the only render boundary SwiftUI has: a
//  helper `func`, a computed `var` and an `.overlay` closure are all inlined
//  into the body that declares them, so none of them would have moved
//  anything. See *Render isolation, in practice* in the repository
//  instructions.
//
//  What leaves here is the coarse flag rather than the environment value:
//  ``SheetPresentation/layout`` changes when the device is turned over and at
//  no other time, so the root view re-renders for a rotation and for nothing
//  else.
//

import SwiftUI

struct SheetLayoutReader: View {
    var presentation: SheetPresentation
    /// Withdrawn along with the sheet: in a side panel nothing reports a top
    /// edge, and the last portrait reading still lands on a landscape map.
    var metrics: SheetMetrics

    #if os(macOS)
    /// No compact height to answer to on a platform this app does not build
    /// for yet — see the `canImport` note in the repository instructions.
    private var layout: SheetLayout { .bottomSheet }
    #else
    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    private var layout: SheetLayout {
        verticalSizeClass == .compact ? .sidePanel : .bottomSheet
    }
    #endif

    var body: some View {
        // Draws nothing and is never announced: this view exists for the
        // environment it sits in, not for anything on screen.
        Color.clear
            .accessibilityHidden(true)
            // `initial`, because a launch straight into landscape is a
            // rotation nothing here ever sees.
            .onChange(of: layout, initial: true) { _, layout in
                presentation.layout = layout
                if layout == .sidePanel { metrics.withdraw() }
            }
    }
}
