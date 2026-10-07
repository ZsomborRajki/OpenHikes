//
//  WalkShareEditorModel.swift
//  OpenHikes
//
//  What the share card editor has settled: where each box was let go, how
//  the photograph is framed, which box is selected.
//
//  Only the *settled* state lives here. A finger dragging a box or pinching
//  the photograph moves it through the gesture's own state, inside the one
//  view being moved, and writes here once when it lifts — so a drag
//  re-renders the box under the finger and nothing else, and the toolbar's
//  share item is rebuilt once per gesture rather than once per frame.
//

import Foundation
import Observation
import SwiftUI

@Observable
final class WalkShareEditorModel {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    let card: WalkShareCard
    private(set) var layout: WalkShareLayout
    private(set) var photoFrame = WalkSharePhotoFrame()
    /// The box whose controls are showing, if any.
    var selection: WalkShareWidget?
    /// The card's size in points: the editor's, which the export renders at
    /// a larger pixel scale.
    private(set) var canvasSize: CGSize = .zero

    @ObservationIgnored private let defaults: UserDefaults

    init(card: WalkShareCard, defaults: UserDefaults) {
        self.card = card
        self.defaults = defaults
        layout = WalkShareLayout.remembered(in: defaults)
    }

    func setCanvasSize(_ size: CGSize) {
        guard size != canvasSize, size.width > 0, size.height > 0 else { return }
        canvasSize = size
        photoFrame = photoFrame.clamped(image: card.photo.size, canvas: size)
    }

    /// Lets `widget` go at `center`, in the card's points — already clamped
    /// and snapped by the box that was dragged.
    func place(_ widget: WalkShareWidget, at center: CGPoint) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        update { layout in
            layout[widget].center = CGPoint(x: center.x / canvasSize.width, y: center.y / canvasSize.height)
        }
    }

    func resize(_ widget: WalkShareWidget, to scale: Double) {
        let range = WalkShareWidgetPlacement.scaleRange
        update { $0[widget].scale = min(max(scale, range.lowerBound), range.upperBound) }
    }

    func setStyle(_ style: WalkShareBoxStyle, of widget: WalkShareWidget) {
        update { layout in
            switch widget {
            case .stats: layout.statsStyle = style
            case .route: layout.routeStyle = style
            }
        }
    }

    func setLineColor(_ color: WalkShareLineColor) {
        update { $0.lineColor = color }
    }

    func toggle(_ stat: WalkShareStat) {
        update { $0 = $0.toggling(stat) }
    }

    func setPhotoFrame(_ frame: WalkSharePhotoFrame) {
        photoFrame = frame.clamped(image: card.photo.size, canvas: canvasSize)
    }

    /// The card as it stands, for the share sheet.
    var shareImage: WalkShareImage {
        WalkShareImage(card: card, layout: layout, photoFrame: photoFrame, canvas: canvasSize)
    }

    /// Every change to the layout is remembered as it is made, so the card
    /// the hiker abandons still teaches the next one where they like things.
    private func update(_ change: (inout WalkShareLayout) -> Void) {
        var changed = layout
        change(&changed)
        guard changed != layout else { return }
        layout = changed
        changed.remember(in: defaults)
    }
}
