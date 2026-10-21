//
//  MapSheet+CommonsPhotos.swift
//  OpenHikes
//
//  The two screens a Wikimedia Commons pin on the *Community* tab's map
//  opens: one photograph — see ``CommonsPhotoView`` — and a group of them too
//  close together to draw apart — see ``CommonsPhotoGroupView``. And the
//  gallery a photograph's screen pushes — see ``CommonsPhotoGallery``.
//
//  Its own file for the reason `MapSheet+Places.swift` is one: the sheet's own
//  file is at the length the linter allows, and these are destinations rather
//  than more of the sheet.
//

import SwiftUI

extension MapSheet {
    /// The photograph, the gallery or the group `route` is about.
    ///
    /// `found` is handed in rather than read here because the model it hangs
    /// off is private to the sheet's own file.
    @ViewBuilder
    func commonsDestination(for route: SheetRoute, among found: CommunityCommonsPhotos) -> some View {
        switch route {
        case let .commonsPhoto(photo):
            CommonsPhotoView(photo, among: found, map: mapController, maker: trailMaker) { photos, opening in
                // Over the photograph's screen rather than in a cover from
                // it, so a rotation moves the gallery instead of closing it,
                // and Back comes back to the photograph.
                presentation.path.append(.commonsGallery(photos, opening))
            }
            // A push over the photograph runs this builder again, and the
            // closure above makes every copy a new view — see
            // `HikeDetailView+Equatable.swift`.
            .equatable()
        case let .commonsGallery(photos, opening):
            CommonsPhotoGallery(
                photos: photos,
                opening: opening,
                mapController: mapController,
                selection: presentation.communityPhotoSelection(for: route),
                // *Show on Map* pops back to the photograph; the sheet has to
                // come down off the spot as well, as it does under a shared
                // hike's gallery.
                onShowOnMap: presentation.restAtMiddleWhenFullHeightScreenPops
            )
        case let .commonsPhotos(photos):
            CommonsPhotoGroupView(photos, among: found, map: mapController) { photo in
                // Over the grid rather than in place of it, so Back comes back
                // to the group.
                presentation.path.append(.commonsPhoto(photo))
            }
            // A push over the grid runs this builder again, and the closure
            // above makes every copy a new view — see
            // `HikeDetailView+Equatable.swift`.
            .equatable()
        case .communityHike, .communityPhoto, .hike, .newPlace, .pendingPhotos, .pendingSubmission, .photo, .place,
            .placesAround, .placesNearby, .recording, .routeStyle, .totals, .trailDraft, .walk:
            EmptyView()
        }
    }
}
