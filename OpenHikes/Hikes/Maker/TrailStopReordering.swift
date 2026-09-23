//
//  TrailStopReordering.swift
//  OpenHikes
//
//  The drag that reorders the maker's route: iOS 27's `reorderable()` on the
//  rows' `ForEach`, and `reorderContainer(for:)` on the list around it.
//
//  As in Apple Maps, a row moves at any time with no Edit/Done mode: a press
//  and hold lifts it, and the trailing swipe stays beside it. The container
//  reports a drop as *these rows, in front of that one*, which
//  ``TrailStopSlot/rearranged(_:moving:before:)`` turns into the list's new
//  order and ``TrailDraft/arrangeRows(_:)`` into the draft's.
//
//  ## What it needs, measured
//
//  Each of these was found in a standalone prototype on iOS 27.0, driven by
//  XCUITest, before it was relied on here:
//
//  - **One `ForEach`, alone among the section's dynamic rows.** A second one
//    beside it — even an empty one — put a row dragged one place up at the
//    end of the list and ignored one dragged one place down. The open fields
//    are rows of the same `ForEach` for that reason.
//  - **No conditional rows.** A `ForEach` whose closure builds its row inside
//    an `if` moves the row on screen and never calls the container.
//  - **Row modifiers after `reorderable()`.** A row's own `listRowInsets`
//    and `listRowSeparator` are dropped, so ``TrailDraftView`` puts them on
//    what ``trailStopsReorderable()`` returns.
//  - **Every drop changes the data.** Neither `.moveDisabled` nor the
//    container's `isEnabled:` stops a row being lifted, and a drop the closure
//    ignores leaves the list drawing the rows where the finger left them. So
//    the open fields drag too, and are named by where they land.
//
//  Short drags were not perfectly repeatable even so: across the prototype's
//  single-`ForEach` variants a one-place move still landed wrong now and then.
//  What a drop *reports* is what the draft and the map follow, and the list
//  redraws to match it, so the two never disagree about the order.
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
