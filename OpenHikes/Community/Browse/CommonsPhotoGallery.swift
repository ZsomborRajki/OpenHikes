//
//  CommonsPhotoGallery.swift
//  OpenHikes
//
//  Wikimedia Commons photographs, full screen, in the gallery a curated
//  route's preview uses — with its credit, its paging and its *Show on Map*.
//
//  Reached two ways, and hosted differently for each. The *Community* tab's
//  photograph screen pushes it onto the sheet's stack — see
//  ``SheetRoute/commonsGallery(_:_:)`` — which is what lets it survive the
//  phone being turned. The maker's place card is already a sheet over the
//  sheet, with no stack of its own to push onto, so it presents this in a
//  cover — see ``TrailDraftPhotoHeader``.
//

import SwiftUI

struct CommonsPhotoGallery: View {
    let photos: [CommonsPhoto]
    /// The one tapped. Only the opening page — paging afterwards is
    /// remembered by ``selection``.
    let opening: CommonsPhoto
    let mapController: MapController
    /// The page the gallery is resting on, kept by whoever outlives this
    /// view — the sheet's presentation, for the pushed gallery, so a rotation
    /// that rebuilds it comes back to the same picture.
    var selection = CommunityPhotoSelection()
    /// Told just before *Show on Map* takes the gallery away, so whatever
    /// presented it gets out of the way of the spot too.
    let onShowOnMap: () -> Void

    var body: some View {
        CommunityPhotoViewer(
            photos: photos.enumerated().map { index, photo in
                CommunityGalleryPhoto(
                    index: index,
                    pin: photo.pin,
                    fileURL: photo.fileURL,
                    contribution: nil,
                    commons: photo.credit
                )
            },
            startIndex: photos.firstIndex(of: opening) ?? 0,
            mapController: mapController,
            onShowOnMap: onShowOnMap,
            selection: selection
        )
    }
}
