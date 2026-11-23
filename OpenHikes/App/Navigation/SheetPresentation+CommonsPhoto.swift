//
//  SheetPresentation+CommonsPhoto.swift
//  OpenHikes
//
//  Opening a Wikimedia Commons photograph the *Community* tab found — see
//  ``CommonsPhotoView`` — or a group of them too close together to draw apart
//  — see ``CommonsPhotoGroupView``. Split from the presentation for length.
//

import Foundation

extension SheetPresentation {
    /// Opens a photograph's screen, on the terms a shared hike's preview
    /// opens on: the sheet makes room, the same photograph is never on the
    /// stack twice, and a different one — or a hike's preview — is replaced
    /// rather than stacked onto. See ``showCommunityPreview(_:)``.
    func showCommonsPhoto(_ photo: CommonsPhoto) {
        showCommunityPreview(.commonsPhoto(photo))
    }

    /// Opens a group's grid, on the same terms: a group is a pin on the same
    /// map. A photograph opened from the grid is the one step deeper there is,
    /// and the grid appends it itself — see `MapSheet+CommonsPhotos.swift`.
    func showCommonsPhotos(_ photos: [CommonsPhoto]) {
        showCommunityPreview(.commonsPhotos(photos))
    }
}
