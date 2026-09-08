//
//  TopEdgeReader.swift
//  OpenHikes
//
//  Reports a view's top edge (global Y), updating continuously as it moves —
//  e.g. while a sheet is dragged between detents.
//

import SwiftUI

extension View {
    /// Calls `action` with this view's top edge in global coordinates whenever it
    /// changes, including during interactive animations like sheet drags.
    ///
    /// Projected to the single `CGFloat` the caller wants rather than watching
    /// the whole frame: the value reaches `SheetMetrics` at touch frequency, so
    /// a reading that also moved when the width changed would write to an
    /// observable on every layout pass. `onGeometryChange` measures without a
    /// container, so nothing here can stretch the view being read.
    func onTopEdgeChange(perform action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { edge in
            action(edge)
        }
    }
}
