//
//  TopEdgeReader.swift
//  OpenTrails
//
//  Reports a view's top edge (global Y), updating continuously as it moves —
//  e.g. while a sheet is dragged between detents.
//

import SwiftUI

extension View {
    /// Calls `action` with this view's top edge in global coordinates whenever it
    /// changes, including during interactive animations like sheet drags.
    func onTopEdgeChange(perform action: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                let topEdge = proxy.frame(in: .global).minY
                Color.clear
                    .onAppear { action(topEdge) }
                    .onChange(of: topEdge) { _, y in action(y) }
            }
        }
    }
}
