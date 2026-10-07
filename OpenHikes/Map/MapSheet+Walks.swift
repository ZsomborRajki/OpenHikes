//
//  MapSheet+Walks.swift
//  OpenHikes
//
//  A walk's summary, pushed onto the sheet — see ``WalkSummaryView``.
//
//  Its own file for the reason ``MapSheetHikes`` is one: the sheet's own file
//  is at the length the linter allows, and this is a destination rather than
//  more of the sheet.
//

import OpenHikesData
import SwiftUI

extension MapSheet {
    /// The summary, with the share card it presents kept by the presentation
    /// rather than by the summary, so a rotation does not close it — see
    /// ``WalkShareSession``.
    func walkDestination(_ walk: HikeWalk, route: SheetRoute) -> some View {
        WalkSummaryView(
            walk: walk,
            walkHighlight: walkHighlight,
            mapController: mapController,
            share: presentation.walkShare(for: route),
            onShowOnMap: presentation.makeRoomForTheMap
        )
    }
}
