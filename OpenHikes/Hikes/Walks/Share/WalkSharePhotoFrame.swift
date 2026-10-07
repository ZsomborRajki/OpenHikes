//
//  WalkSharePhotoFrame.swift
//  OpenHikes
//
//  Which part of the photograph fills the share card: how far it is zoomed
//  past filling the card, and how far it is moved from the middle.
//
//  The one rule is that the card never shows anything but photograph — no
//  zoom below filling it and no pan past an edge — so the frame is clamped
//  rather than validated: whatever a gesture proposes, the nearest frame that
//  keeps the rule is the one drawn.
//

import CoreGraphics

nonisolated struct WalkSharePhotoFrame: Equatable, Sendable {
    /// 1 fills the card exactly along one side.
    var zoom: CGFloat = 1
    /// How far the photograph's centre sits from the card's, as a fraction
    /// of the card's width and height — fractions so the export, drawn at
    /// another size, crops the same picture.
    var offset: CGVector = .zero

    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// The size the photograph is drawn at on a card of `canvas` points.
    func drawnSize(of image: CGSize, on canvas: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return canvas }
        let fill = max(canvas.width / image.width, canvas.height / image.height) * zoom
        return CGSize(width: image.width * fill, height: image.height * fill)
    }

    /// This frame brought back inside the rule: zoom in range, and no edge of
    /// the photograph inside the card.
    func clamped(image: CGSize, canvas: CGSize) -> Self {
        guard canvas.width > 0, canvas.height > 0 else { return self }
        var frame = self
        frame.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let drawn = frame.drawnSize(of: image, on: canvas)
        let slackX = max(0, (drawn.width - canvas.width) / 2) / canvas.width
        let slackY = max(0, (drawn.height - canvas.height) / 2) / canvas.height
        frame.offset = CGVector(
            dx: min(max(offset.dx, -slackX), slackX),
            dy: min(max(offset.dy, -slackY), slackY)
        )
        return frame
    }
}
