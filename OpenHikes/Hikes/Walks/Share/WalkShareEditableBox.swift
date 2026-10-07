//
//  WalkShareEditableBox.swift
//  OpenHikes
//
//  A box on the share card that a finger can move and pinch, and VoiceOver
//  can step about with named actions — see `WalkShareBoxActions`.
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
        let target = WalkShareLayout.target(
            center: placement.center,
            translation: translation,
            boxSize: boxSize,
            canvas: size
        )
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
            .modifier(WalkShareBoxActions(widget: widget, model: model, boxSize: boxSize))
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
                let moved = WalkShareLayout.target(
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
                // A box grown against an edge is drawn pulled back onto the
                // card; this stores where it was drawn. `boxSize` is already
                // the pinched size — it is measured every frame of the pinch —
                // so it is not multiplied by the magnification again.
                let placement = model.layout[widget]
                let center = CGPoint(x: placement.center.x * size.width, y: placement.center.y * size.height)
                model.place(widget, at: WalkShareLayout.clampedCenter(center, boxSize: boxSize, canvas: size))
            }
    }
}

/// The drag and the pinch as actions VoiceOver can take, which has neither:
/// each moves the box one step, selects it as a drag does, and says where it
/// ended up — the box's own value is its figures, and is left to them.
private struct WalkShareBoxActions: ViewModifier {
    let widget: WalkShareWidget
    let model: WalkShareEditorModel
    let boxSize: CGSize

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Move Up") { act { model.step(widget, .up, boxSize: boxSize) } }
            .accessibilityAction(named: "Move Down") { act { model.step(widget, .down, boxSize: boxSize) } }
            .accessibilityAction(named: "Move Left") { act { model.step(widget, .left, boxSize: boxSize) } }
            .accessibilityAction(named: "Move Right") { act { model.step(widget, .right, boxSize: boxSize) } }
            .accessibilityAction(named: "Center") { act { model.center(widget, boxSize: boxSize) } }
            .accessibilityAction(named: "Larger") { act { model.rescale(widget, larger: true, boxSize: boxSize) } }
            .accessibilityAction(named: "Smaller") { act { model.rescale(widget, larger: false, boxSize: boxSize) } }
    }

    private func act(_ change: () -> Void) {
        model.selection = widget
        change()
        AccessibilityNotification.Announcement(model.spokenPlacement(of: widget)).post()
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
            // The pan and the zoom, for VoiceOver, one step at a time.
            .accessibilityAction(named: "Zoom In") { model.zoomPhoto(in: true) }
            .accessibilityAction(named: "Zoom Out") { model.zoomPhoto(in: false) }
            .accessibilityAction(named: "Move Up") { model.stepPhoto(.up) }
            .accessibilityAction(named: "Move Down") { model.stepPhoto(.down) }
            .accessibilityAction(named: "Move Left") { model.stepPhoto(.left) }
            .accessibilityAction(named: "Move Right") { model.stepPhoto(.right) }
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
