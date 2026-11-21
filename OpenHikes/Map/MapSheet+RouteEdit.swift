//
//  MapSheet+RouteEdit.swift
//  OpenHikes
//
//  The two screens about a hike's line, pushed onto the sheet: how it is
//  drawn — see ``RouteStyleView`` — and *Edit Route* — see ``RouteTrimView``.
//
//  Its own file for the reason ``MapSheetHikes`` is one: the sheet's own file
//  is at the length the linter allows, and this is a destination rather than
//  more of the sheet.
//

import OpenHikesData
import SwiftUI

extension MapSheet {
    /// A switch of its own so the sheet's list of destinations stays one the
    /// linter allows.
    @ViewBuilder
    func routeDestination(for route: SheetRoute) -> some View {
        switch route {
        case let .routeStyle(hike):
            RouteStyleView(hike: hike)
        case let .routeEdit(hike):
            routeEditDestination(of: hike, route: route)
        case .commonsGallery, .commonsPhoto, .commonsPhotos, .communityHike, .communityPhoto, .hike, .newPlace,
            .offlineCountries, .pendingPhotos, .pendingSubmission, .photo, .place, .placesAround, .placesNearby,
            .recording, .totals, .trailDraft, .walk:
            EmptyView()
        }
    }

    /// *Edit Route*. Its cuts are kept by the presentation rather than by
    /// the screen, so a rotation keeps them — see ``RouteTrimSession``.
    private func routeEditDestination(of hike: Hike, route: SheetRoute) -> some View {
        let line = presentation.hikeInteraction(for: hike).line
        return RouteTrimView(
            hike: hike,
            line: line,
            session: presentation.routeTrim(for: route),
            preview: appModel.routeTrim,
            health: routeEditHealth,
            routing: RouteReroute.Services(
                router: appModel.trailMaker.hikingRouter,
                graph: appModel.trailGraphProvider
            ),
            onFirstAppear: {
                // Once a visit: a turn of the phone appears the screen again,
                // and must not take the camera off where the hiker has it.
                guard presentation.claimsFirstFraming(of: route) else { return }
                presentation.makeRoomForTheMap()
                mapController.fitToRoute()
            },
            onShowStretch: { stretch in
                presentation.makeRoomForTheMap()
                mapController.showDrawnLine(stretch)
            },
            onDone: {
                guard presentation.path.last == route else { return }
                presentation.path.removeLast()
            }
        )
        .showing(line, of: hike, in: appModel)
    }

    /// What an edit needs to replace a hike's workout, on a launch that has
    /// Health at all — see ``RouteEditWorkout``.
    private var routeEditHealth: RouteEditWorkout.Health? {
        let recorder = appModel.hikeRecorder
        return recorder.workoutWriter.map { writer in
            RouteEditWorkout.Health(
                writer: writer,
                queue: recorder.workoutQueue,
                container: appModel.container,
                defaults: appModel.defaults,
                weatherState: recorder.weatherState
            )
        }
    }
}
