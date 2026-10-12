//
//  TrailPlacePhotoHeader.swift
//  OpenHikes
//
//  The photograph at the head of the maker's place card, when the card is
//  about one — see ``TrailDraftPhotos``.
//
//  Wide rather than square, and above the title, because the picture is what
//  the hiker tapped to see; the card under it is what they can do about it.
//  The credit sits on the picture, as it does in every gallery that shows a
//  Commons photograph, because the licence is owed wherever it is shown — see
//  ``PhotoLicenceCredit``. A tap opens it full screen in the gallery a curated
//  route's preview uses, paging through everything the searches found.
//

import OpenHikesData
import SwiftUI

struct TrailPlacePhotoHeader: View {
    let photo: CommonsPhoto
    let maker: TrailDraftController
    let mapController: MapController

    @State private var image: Image?
    @State private var isViewing = false

    private static let height: CGFloat = 180
    private static let cornerRadius: CGFloat = 12
    /// The card is a phone's width at most, and the picture is drawn at
    /// three times its points.
    private static let maxPixelSize = 1200

    var body: some View {
        Button { isViewing = true } label: {
            Color(.secondarySystemFill)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .overlay {
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PhotoLicenceCredit.line(author: photo.credit.author, licence: photo.credit.licence))
        .accessibilityHint("Opens the photo full screen")
        .accessibilityIdentifier("trail-place-photo")
        // Beside the button rather than inside it, so a tap on the credit
        // opens its menu and not the viewer.
        .overlay(alignment: .bottomLeading) {
            PhotoLicenceCredit(author: photo.credit.author, licence: photo.credit.licence)
                // White over a photograph, rather than the maker's accent the
                // menu's label would otherwise take — green on a meadow.
                .tint(.white)
                .padding(8)
        }
        .task(id: photo.fileURL) {
            image = nil
            image = await CommunityPhotoTile.decode(photo.fileURL, maxPixelSize: Self.maxPixelSize)
        }
        .fullScreenCover(isPresented: $isViewing) {
            TrailDraftPhotoViewer(
                photos: maker.photos.photos,
                opening: photo,
                mapController: mapController
            ) {
                isViewing = false
            }
        }
    }
}

/// Every photograph the maker found, full screen — the curated preview's
/// gallery, with its credit, its paging and its *Show on Map*, in a cover of
/// its own because the card it opens from is already a sheet.
private struct TrailDraftPhotoViewer: View {
    let photos: [CommonsPhoto]
    let opening: CommonsPhoto
    let mapController: MapController
    let onClose: () -> Void

    var body: some View {
        let gallery = photos.enumerated().map { index, photo in
            CommunityGalleryPhoto(
                index: index,
                pin: photo.pin,
                fileURL: photo.fileURL,
                contribution: nil,
                commons: photo.credit
            )
        }
        NavigationStack {
            CommunityPhotoViewer(
                photos: gallery,
                startIndex: photos.firstIndex(of: opening) ?? 0,
                mapController: mapController,
                // The camera has moved to the spot; the cover is what is in
                // the way of seeing it.
                onShowOnMap: onClose
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .accessibilityIdentifier("trail-photo-viewer-close")
                }
            }
        }
    }
}
