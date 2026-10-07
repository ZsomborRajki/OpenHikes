//
//  WalkShareImage.swift
//  OpenHikes
//
//  A walk's share card on its way to the share sheet, drawn only once the
//  hiker has picked where it is going.
//
//  The share item is built every time the layout settles, and a drawn card is
//  a few megabytes of JPEG, so it carries what to draw rather than the
//  drawing: the system calls the exporter once, for the destination chosen,
//  and the card is rendered then.
//

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct WalkShareImage: Transferable, Sendable {
    let card: WalkShareCard
    let layout: WalkShareLayout
    let photoFrame: WalkSharePhotoFrame
    /// The editor's size, in points. The export draws at exactly this size
    /// and a larger pixel scale, which is what makes it the editor's picture.
    let canvas: CGSize

    /// The picture's width in pixels: what a story or a feed shows full
    /// width, and no more than the photograph underneath it can fill.
    static let pixelWidth: CGFloat = 1080
    static let quality: CGFloat = 0.9

    struct RenderFailed: Error {}

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { image in
            guard let data = await image.render() else { throw RenderFailed() }
            return data
        }
        .suggestedFileName { image in
            GPXExport.shareCardFileName(hikeTitle: image.card.figures.title, walkedOn: image.card.figures.startedAt)
        }
    }

    /// The card as JPEG, or `nil` for a card with no size yet.
    @MainActor
    func render() -> Data? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let renderer = ImageRenderer(content: WalkShareCanvas(size: canvas) {
            WalkSharePhotoLayer(photo: card.photo, frame: photoFrame, size: canvas)
        } box: { widget in
            WalkSharePlacedBox(widget: widget, card: card, layout: layout, size: canvas)
        })
        renderer.scale = Self.pixelWidth / canvas.width
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: Self.quality)
    }
}
