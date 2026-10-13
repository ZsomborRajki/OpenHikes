//
//  CommonsPhotoView.swift
//  OpenHikes
//
//  A Wikimedia Commons photograph the *Community* tab found, on its own
//  screen — see ``CommunityCommonsPhotos``.
//
//  Laid out as the maker's place card is when it is about a photograph,
//  because it is the same thing reached from the other side: the picture at
//  the head with its credit on it (a tap opens it full screen), what it is and
//  when it was taken, the place, and what can be done about it. See
//  ``TrailPlacePhotoHeader``.
//
//  The verb is *Plan a Trail Here*: the trail maker opens with **where the
//  camera stood** as the destination and the start left open, as Apple Maps'
//  Directions opens. Where the camera stood, not what it was pointed at,
//  because that is the only position Commons knows and it is the spot a
//  hiker can walk to and see the view from. See
//  ``TrailDraftController/plan(to:)``.
//

import Algorithms
import CoreLocation
import OpenHikesData
import OpenHikesShared
import SwiftUI

struct CommonsPhotoView: View {
    let photo: CommonsPhoto
    /// What the tab found, for the full-screen viewer to page through.
    let found: CommunityCommonsPhotos
    let mapController: MapController
    let maker: TrailDraftController

    /// The address MapKit found, `nil` until it answers and for a spot it
    /// cannot place.
    @State private var address: String?
    /// The photograph the map was last asked to bring into view, so it is
    /// asked once. `.task` runs again when the full-screen viewer closes, and
    /// that viewer's own *Show on Map* has just put the camera on whichever
    /// picture it was paged to.
    @State private var framed: URL?

    init(_ photo: CommonsPhoto, among found: CommunityCommonsPhotos, map: MapController, maker: TrailDraftController) {
        self.photo = photo
        self.found = found
        mapController = map
        self.maker = maker
    }

    var body: some View {
        Group {
            if let camera = photo.pin.coordinate {
                content(at: camera)
            } else {
                // Unreachable: a photograph with no camera has no pin to tap.
                ContentUnavailableView("No Location", systemImage: "mappin.slash")
            }
        }
        .navigationTitle(Text("Photo"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func content(at camera: CLLocationCoordinate2D) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                TrailPlacePhotoHeader(
                    photo: photo,
                    // The tab's answer to page through, unless a newer one
                    // has replaced the answer this photograph came from.
                    gallery: { [found, photo] in found.photos.contains(photo) ? found.photos : [photo] },
                    mapController: mapController,
                    accessibilityIdentifier: "commons-photo-header"
                )
                header
                actions(at: camera)
                TrailPlaceFactsAndLocation(facts: [], address: address, coordinate: camera)
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .accessibilityIdentifier("commons-photo-screen")
        .task(id: photo.fileURL) {
            if framed != photo.fileURL {
                framed = photo.fileURL
                // Up from under the sheet, where a pin near the bottom of the
                // search area would otherwise be hidden behind the screen it
                // opened — and nothing more. The pin was tapped where it
                // stood, so the zoom stays the hiker's, and the pins around it
                // are still on screen after Back. *Show on Map* below is the
                // close look.
                mapController.reveal(camera)
                address = nil
            }
            // Asked again only if the viewer opening cancelled the last ask.
            guard address == nil else { return }
            address = await maker.address(at: camera)
        }
    }

    private var header: some View {
        PlaceCardHeader {
            TrailPlaceBadge(systemImage: "photo", tint: .purple)
        } title: {
            Text("Photo")
                .accessibilityAddTraits(.isHeader)
        } subtitle: {
            Text(subtitle)
        }
    }

    private var subtitle: String {
        [
            String(localized: "Taken \(photo.pin.capturedAt.formatted(date: .abbreviated, time: .omitted))"),
            String(localized: "Wikimedia Commons"),
        ].joined(separator: " · ")
    }

    private func actions(at camera: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 8) {
            Button {
                maker.plan(to: photo)
                HapticMoment.targetHit.play()
            } label: {
                Label("Plan a Trail Here", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the trail maker with this spot as the destination")
            .accessibilityIdentifier("commons-photo-plan-trail")
            Button {
                mapController.showPhotoSpot(camera)
            } label: {
                Label("Show on Map", systemImage: "map")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("commons-photo-show-on-map")
            ShareLink(
                item: TrailPlaceCoordinates.mapsURL(camera, named: String(localized: "Photo")),
                subject: Text("Photo"),
                message: Text(
                    [address, TrailPlaceCoordinates.text(camera), photo.credit.licence.sourceURL.absoluteString]
                        .compacted()
                        .joined(separator: "\n")
                )
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(TrailPlaceActionLabelStyle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("commons-photo-share")
        }
        .buttonBorderShape(.roundedRectangle(radius: TrailPlaceActionLabelStyle.cornerRadius))
        // One height for the row, whichever word needs the most room at the
        // hiker's type size.
        .fixedSize(horizontal: false, vertical: true)
    }
}
