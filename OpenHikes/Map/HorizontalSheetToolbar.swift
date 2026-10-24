//
//  HorizontalSheetToolbar.swift
//  OpenHikes
//
//  Keeps the toolbar of the map screen's sheet across the top of the sheet on
//  an iPhone Duo, rather than standing it up along the sheet's trailing edge.
//
//  A closed Duo puts a sheet's toolbar in a vertical bar by default, which
//  reads well at the middle and large detents and breaks at the compact one:
//  eighty points of sheet hold the *Back* button and no more, and the
//  *Start Hike* button below it hung out of the bottom of the sheet, half
//  drawn, fused to *Back* by the glass between them. On every other iPhone that
//  detent is one row — back, title, the hike's action — which is the row the
//  detent was sized for, so the sheet keeps it here too. Apple's guidance
//  names this as the one place to opt out: a sheet on the outer display, where
//  "the system presents bars vertically for sheets by default". Everything
//  outside the sheet keeps the system's bars.
//
//  `toolbarVerticalBehavior(_:)` is iOS 27.1's, and CI builds with Xcode 27.0,
//  whose SDK does not have it. `compiler(>=6.4)` cannot tell the two apart —
//  both are Swift 6.4 — so the gate is the SwiftUI module's own version: 8.0.85
//  in the 27.1 SDK, 8.0.84 in 27.0's.
//

import SwiftUI

extension View {
    /// The sheet's toolbar across the top of the sheet, wherever the system
    /// would stand it up on the side. See this file's header.
    @ViewBuilder
    func horizontalSheetToolbar() -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
