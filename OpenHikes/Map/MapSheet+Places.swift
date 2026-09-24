//
//  MapSheet+Places.swift
//  OpenHikes
//
//  A hike's place, pushed onto the sheet. See ``HikePlaceView``.
//
//  Its own file for the reason ``MapSheetHikes`` is one: the sheet's own file
//  is at the length the linter allows, and this is a destination rather than
//  more of the sheet.
//

import SwiftUI

extension MapSheet {
    /// One of a hike's places.
    func placeDestination(_ placeID: UUID, of hike: Hike) -> some View {
        HikePlaceView(
            hike: hike,
            placeID: placeID,
            mapController: mapController,
            photoCapture: photoCapture,
            photoPins: photoPins,
            placePins: placePins,
            onShowOnMap: presentation.makeRoomForTheMap,
            onOpenPhoto: { photo in presentation.path.append(.photo(hike, photo.id)) },
            onOpenPlace: { placeID in openPlace(placeID, of: hike) }
        )
    }

    /// Pushes one of a hike's places — or, from another place's screen,
    /// replaces it, so tapping from pin to pin does not stack a screen per
    /// tap under the back button.
    func openPlace(_ placeID: UUID, of hike: Hike) {
        if case let .place(shown, shownID) = presentation.path.last, shown.id == hike.id {
            guard shownID != placeID else { return }
            presentation.path[presentation.path.count - 1] = .place(hike, placeID)
        } else {
            presentation.path.append(.place(hike, placeID))
        }
    }
}
