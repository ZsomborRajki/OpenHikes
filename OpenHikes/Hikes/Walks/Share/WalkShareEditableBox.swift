//
//  WalkShareEditableBox.swift
//  OpenHikes
//
//  A box on the share card that a finger can move and pinch.
//
//  The gesture's progress is this view's own `@GestureState`, so a drag
//  re-renders this box and nothing above it; the model hears once, when the
//  finger lifts. The box fills the whole card so it can draw the centre guide
//  across it, but only the box itself takes touches — the rest of the layer
//  is empty, and a touch there reaches the box or the photograph underneath.
//

import SwiftUI

struct WalkShareEditableBox: View {
    let widget: WalkShareWidget
    let model: WalkShareEditorModel
    let size: CGSize

    @GestureState private var translation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    /// The box's size as drawn, which is what keeps it on the card.
    @State private var boxSize: CGSize = .zero

    /// The selected box's dashed outline: a little rounder than the card
    /// backing it surrounds, since it sits outside it.
    private static let outlineRadius: CGFloat = 22
    private static let outlineWidth: CGFloat = 1.5
    private static let outlineDash: [CGFloat] = [6, 4]

    var body: some View {
        let placement = model.layout[widget]
        let range = WalkShareWidgetPlacement.scaleRange
        let scale = min(max(placement.scale * magnification, range.lowerBound), range.upperBound)
        let isDragging = translation != .zero
        let target = Self.target(center: placement.center, translation: translation, boxSize: boxSize, canvas: size)
        let isSelected = model.selection == widget

        ZStack(alignment: .topLeading) {
            if isDragging, target.isSnapped {
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 1, height: size.height)
                    .position(x: size.width / 2, y: size.height / 2)
                    .allowsHitTesting(false)
            }
            WalkShareBoxContent(
                widget: widget,
                card: model.card,
                layout: model.layout,
                metric: WalkShareMetrics.unit(for: size) * scale
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { boxSize = $0 }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.outlineRadius * WalkShareMetrics.unit(for: size) * scale)
                        .strokeBorder(.white, style: StrokeStyle(lineWidth: Self.outlineWidth, dash: Self.outlineDash))
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(drag.simultaneously(with: pinch))
            .onTapGesture { model.selection = isSelected ? nil : widget }
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("Shows this box's options")
            .accessibilityIdentifier("walk-share-box-\(widget.rawValue)")
            .position(target.center)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Measured in the window rather than in the box: the box follows the
    /// finger, so a translation measured in its own coordinates chases itself
    /// and the box lands about halfway to where it was dragged.
    private var drag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in
                let placement = model.layout[widget]
                let moved = Self.target(
                    center: placement.center,
                    translation: value.translation,
                    boxSize: boxSize,
                    canvas: size
                )
                model.selection = widget
                model.place(widget, at: moved.center)
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in state = value.magnification }
            .onEnded { value in
                model.selection = widget
                model.resize(widget, to: model.layout[widget].scale * value.magnification)
                // A box grown against an edge is pushed back onto the card
                // the next time it settles; this settles it now.
                let placement = model.layout[widget]
                let grown = CGSize(
                    width: boxSize.width * value.magnification,
                    height: boxSize.height * value.magnification
                )
                let center = CGPoint(x: placement.center.x * size.width, y: placement.center.y * size.height)
                model.place(widget, at: WalkShareLayout.clampedCenter(center, boxSize: grown, canvas: size))
            }
    }

    /// Where a box whose settled centre is `center` (a fraction of the card)
    /// lands after `translation`: on the card, clear of the wordmark, and on
    /// the middle line when it came close.
    static func target(
        center: CGPoint,
        translation: CGSize,
        boxSize: CGSize,
        canvas: CGSize
    ) -> (center: CGPoint, isSnapped: Bool) {
        let proposed = CGPoint(
            x: center.x * canvas.width + translation.width,
            y: center.y * canvas.height + translation.height
        )
        let snapped = WalkShareLayout.snapped(proposed, canvas: canvas)
        return (WalkShareLayout.clampedCenter(snapped.center, boxSize: boxSize, canvas: canvas), snapped.isSnapped)
    }
}

/// The photograph under the boxes, which a drag pans and a pinch zooms, and a
/// tap uses to put the selected box's controls away.
struct WalkShareEditablePhoto: View {
    let model: WalkShareEditorModel
    let size: CGSize

    @GestureState private var translation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        WalkSharePhotoLayer(photo: model.card.photo, frame: live(model.photoFrame), size: size)
            .contentShape(.rect)
            .gesture(pan.simultaneously(with: zoom))
            .onTapGesture { model.selection = nil }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Photo")
            .accessibilityHint("Hides the box options")
    }

    /// In the window's coordinates, for the reason the box's drag is.
    private var pan: some Gesture {
        DragGesture(coordinateSpace: .global)
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in
                model.setPhotoFrame(moved(model.photoFrame, by: value.translation, zoomedBy: 1))
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in state = value.magnification }
            .onEnded { value in
                model.setPhotoFrame(moved(model.photoFrame, by: .zero, zoomedBy: value.magnification))
            }
    }

    private func live(_ frame: WalkSharePhotoFrame) -> WalkSharePhotoFrame {
        moved(frame, by: translation, zoomedBy: magnification)
    }

    private func moved(
        _ frame: WalkSharePhotoFrame,
        by translation: CGSize,
        zoomedBy magnification: CGFloat
    ) -> WalkSharePhotoFrame {
        guard size.width > 0, size.height > 0 else { return frame }
        var moved = frame
        moved.zoom *= magnification
        moved.offset.dx += translation.width / size.width
        moved.offset.dy += translation.height / size.height
        return moved.clamped(image: model.card.photo.size, canvas: size)
    }
}
