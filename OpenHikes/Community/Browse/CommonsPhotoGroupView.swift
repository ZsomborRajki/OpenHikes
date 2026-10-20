//
//  CommonsPhotoGroupView.swift
//  OpenHikes
//
//  Wikimedia Commons photographs the *Community* tab found standing too close
//  together on the map to draw apart, on a screen of their own — see
//  `MapCommunityCommonsPhotos.swift` for how the map groups them.
//
//  A grid, as Photos opens a group on its map (the user's call of
//  2026-10-20, over zooming the map in until the group comes apart and over
//  opening the newest photograph with the rest a swipe away). The pictures
//  are what the hiker tapped to see, all of them at once, and photographs
//  taken from one spot are a group no zoom ever separates. The map is left
//  where it is: a tile opens that photograph's own screen over this one —
//  see ``CommonsPhotoView`` — and Back comes back here.
//
//  The credit is one sentence for the set, as under a curated route's strip:
//  each photograph's own credit is on its screen, and on its tile to a screen
//  reader, and a grid of thumbnails has no room for sixteen of them.
//

import Algorithms
import CoreLocation
import OpenHikesData
import SwiftUI

struct CommonsPhotoGroupView: View {
    /// Newest first — see ``CommunityCommonsPhotoAnnotation/photos(in:)``.
    let photos: [CommonsPhoto]
    /// What the tab found, which a tile asks for a photograph's file again
    /// once a later search has deleted it.
    let found: CommunityCommonsPhotos
    let mapController: MapController
    /// Opens a photograph's screen over this one.
    let onOpen: (CommonsPhoto) -> Void

    /// Whether the map has been asked to bring the group into view, so it is
    /// asked once: `.task` runs again when a photograph opened from here is
    /// popped, and that photograph's screen may have moved the map since.
    @State private var framed = false

    private static let tileMinimum: CGFloat = 96
    private static let tileSpacing: CGFloat = 4

    init(
        _ photos: [CommonsPhoto],
        among found: CommunityCommonsPhotos,
        map: MapController,
        onOpen: @escaping (CommonsPhoto) -> Void
    ) {
        self.photos = photos
        self.found = found
        mapController = map
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
                header
                grid
                Text("Photos from Wikimedia Commons, each under its own licence. Open one to see who took it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("commons-photo-group-attribution")
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .accessibilityIdentifier("commons-photo-group-screen")
        .navigationTitle(Text("Photos"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard !framed, let spot = Self.spot(of: photos) else { return }
            framed = true
            // Up from under the sheet, at the hiker's zoom — for the reason
            // ``CommonsPhotoView`` gives.
            mapController.reveal(spot)
        }
    }

    private var header: some View {
        PlaceCardHeader {
            TrailPlaceBadge(systemImage: "photo.stack", tint: .purple)
        } title: {
            Text("\(photos.count) photos")
                .accessibilityAddTraits(.isHeader)
        } subtitle: {
            Text(subtitle)
        }
    }

    /// When they were taken, as years, and where they come from.
    private var subtitle: String {
        let taken = photos.map(\.pin.capturedAt)
        guard let (oldest, newest) = taken.minAndMax() else { return String(localized: "Wikimedia Commons") }
        return [
            String(localized: "Taken \((oldest..<newest).formatted(.interval.year()))"),
            String(localized: "Wikimedia Commons"),
        ].joined(separator: " · ")
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.tileMinimum), spacing: Self.tileSpacing)],
            spacing: Self.tileSpacing
        ) {
            ForEach(photos.enumerated(), id: \.element.credit.licence.sourceURL) { index, photo in
                Button {
                    onOpen(photo)
                } label: {
                    CommonsPhotoGroupTile(photo: photo, found: found)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.label(for: photo))
                .accessibilityHint("Opens the photo")
                .accessibilityIdentifier("commons-photo-group-\(index)")
            }
        }
    }

    /// The credit the map's pin would have spoken, and when — the one thing
    /// that tells two photographs by the same person apart without seeing
    /// them.
    private static func label(for photo: CommonsPhoto) -> String {
        let credit = PhotoLicenceCredit.line(author: photo.credit.author, licence: photo.credit.licence)
        let taken = photo.pin.capturedAt.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(credit), taken \(taken)")
    }

    /// Where the group stands: the newest photograph's camera, the one its
    /// pin drew — the rest stood within a thumbnail of it. Not the middle of
    /// them all, which across the 180th meridian is the other side of the
    /// world.
    static func spot(of photos: [CommonsPhoto]) -> CLLocationCoordinate2D? {
        photos.lazy.compactMap(\.pin.coordinate).first
    }
}

extension CommonsPhotoGroupView: Equatable {
    /// The photographs and what the screen draws from, by identity — and not
    /// ``onOpen``, which appends to the sheet's path whichever copy of it
    /// runs. See `HikeDetailView+Equatable.swift`.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.photos == rhs.photos && lhs.found === rhs.found && lhs.mapController === rhs.mapController
    }
}

/// One photograph of the group, square, as wide as its column.
private struct CommonsPhotoGroupTile: View {
    let photo: CommonsPhoto
    let found: CommunityCommonsPhotos

    @State private var image: Image?

    private static let cornerRadius: CGFloat = 8
    /// A column is a third of a phone's width at most, drawn at three times
    /// its points.
    private static let maxPixelSize = 480

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
            .task(id: photo.fileURL) { await load() }
    }

    private func load() async {
        // The task runs again whenever the grid reappears — Back from a
        // photograph opened here — and a picture already drawn is not
        // decoded twice.
        guard image == nil else { return }
        if let decoded = await CommunityPhotoTile.decode(photo.fileURL, maxPixelSize: Self.maxPixelSize) {
            image = decoded
            return
        }
        // Deleted with the answer it came in, two searches ago — the case
        // ``CommunityCommonsPhotos/usable(_:)`` exists for.
        guard let usable = await found.usable(photo), usable != photo else { return }
        image = await CommunityPhotoTile.decode(usable.fileURL, maxPixelSize: Self.maxPixelSize)
    }
}
