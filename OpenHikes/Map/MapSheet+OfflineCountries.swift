//
//  MapSheet+OfflineCountries.swift
//  OpenHikes
//
//  The two screens about the whole library or the whole device rather than
//  one hike: the totals, and *Offline Maps*, pushed onto the sheet from *Map
//  Modes* — see ``OfflineCountriesScreen``.
//
//  Its own file for the reason `MapSheet+Places.swift` is one: the sheet's
//  own file is at the length the linter allows.
//

import SwiftUI

extension MapSheet {
    /// A switch of its own so the sheet's list of destinations stays one the
    /// linter allows.
    @ViewBuilder
    func overviewDestination(for route: SheetRoute) -> some View {
        switch route {
        case .totals:
            LibraryTotalsView(onOpenHike: openRecord)
        case .offlineCountries:
            OfflineCountriesScreen(
                countries: appModel.offlineCountries,
                locationManager: appModel.locationManager,
                mapController: mapController,
                presentation: presentation,
                list: presentation.offlineCountriesList(for: route)
            )
        case .commonsGallery, .commonsPhoto, .commonsPhotos, .communityHike, .communityPhoto, .hike, .newPlace,
            .pendingPhotos, .pendingSubmission, .photo, .place, .placesAround, .placesNearby, .recording,
            .routeStyle, .trailDraft, .walk:
            EmptyView()
        }
    }
}
