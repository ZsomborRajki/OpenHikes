//
//  TrailStopReordering.swift
//  OpenHikes
//
//  EXPERIMENT — iOS 27's `reorderable()` on the stops' `ForEach`, and
//  `reorderContainer(for:)` on the list around it, in place of `onMove`.
//
//  What a standalone prototype measured on iOS 27.0, and why the main line
//  uses `onMove` instead:
//
//  - A row dragged one place up lands at the *end* of the list, and one
//    dragged one place down is ignored. Longer drags land where they should.
//  - A reorderable `ForEach` drops its rows' own `listRowInsets` and
//    `listRowSeparator`, so they go on what ``trailStopsReorderable()``
//    returns rather than on the rows.
//  - Rows built as conditional content (`if`, `if`/`else`) move on screen and
//    never reach the container.
//
//  Neither modifier exists before the iOS 27 SDK, and CodeQL still builds on
//  Xcode 26.6, so both are the identity on an older compiler.
//

import SwiftUI

extension DynamicViewContent {
    /// Lets a press and hold lift one of these rows and drop it among the
    /// others. The drop reaches ``SwiftUI/View/trailStopReorderContainer(_:)``.
    func trailStopsReorderable() -> some View {
        #if compiler(>=6.4)
        reorderable()
        #else
        self
        #endif
    }
}

extension View {
    /// Where a drop among the stops is handed over: the dragged rows'
    /// identifiers, and the row they now sit in front of, or `nil` for the end.
    func trailStopReorderContainer(_ move: @escaping (_ sources: [String], _ before: String?) -> Void) -> some View {
        #if compiler(>=6.4)
        reorderContainer(for: TrailStopSlot.self) { difference in
            switch difference.destination.position {
            case .before(let id): move(difference.sources, id)
            case .end: move(difference.sources, nil)
            }
        }
        #else
        self
        #endif
    }
}
