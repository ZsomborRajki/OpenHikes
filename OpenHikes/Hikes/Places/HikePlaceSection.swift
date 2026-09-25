//
//  HikePlaceSection.swift
//  OpenHikes
//
//  The places marked along a saved trail, on the trail's own screen.
//
//  Its own view for the reason every other section of the detail screen is one
//  — see ``HikePhotoSection``: a hike's places arrive from CloudKit on their
//  own schedule, and that write should redraw a short list rather than the
//  elevation chart, the stats grid and the whole action bar with it.
//
//  ## A row opens the place, and the section can find more
//
//  Each row opens the place's own screen — ``HikePlaceView`` — where its
//  photographs are added and, for a place the hiker made, its name and kind
//  changed. The route itself is still not editable here; the places along it
//  are the part of a finished trail a hiker adds to.
//
//  *Find Places Along Trail* asks OpenStreetMap what the line passes, for a
//  trail that never went through the maker's *Search this area* — a recorded
//  walk, an imported file, a hike saved from somebody else. See
//  ``TrailPlaceCorridorSearch``.
//
//  The switch beside the heading takes every saved hike's places off the map
//  and deletes none of them — see ``TrailPlacePinController/showsPins``. The
//  pins are claimed by the screen around this section, not by it, so they
//  outlast a flip to the hike's History — see ``HikePlacePinClaim``.
//
//  ## Absent only when there is nothing to show and nothing to offer
//
//  A hike with no places draws the section when it can offer the search —
//  a line to search along, and a launch that may ask OpenStreetMap — and
//  nothing otherwise, which is every hike under a test launch and a hike with
//  no route.
//

import OpenHikesData
import SwiftUI

struct HikePlaceSection: View {
    let hike: Hike
    /// Holds the switch beside the heading that takes these places off the
    /// map. The pins themselves are claimed by the screen around this
    /// section — see ``HikePlacePinClaim``. `nil` in a preview, and in a test
    /// that has no map, and then there is no switch.
    var mapPins: TrailPlacePinController?
    /// Where *Find Places Along Trail* asks, or `nil` for a launch that must
    /// not ask anything — see ``OpenHikesModel/makeTrailPointSource()``.
    var search: TrailPlaceSearchScope?
    /// Opens one place's screen.
    var onOpen: (UUID) -> Void = { _ in /* no-op default */ }

    @State private var isSearching = false

    private var canSearch: Bool {
        guard let search, hike.isAttached else { return false }
        return hike.pointCount > 1 && !hike.isRecording && !search.symbols.isEmpty
    }

    @ViewBuilder var body: some View {
        // Ordered once and handed down, the way ``HikePhotoSection`` orders
        // its photographs once: ``Hike/orderedPlaces`` projects every row and
        // sorts them against the route, and asking twice in one pass would do
        // all of it twice.
        let rows = hike.orderedPlaces
        if !rows.isEmpty || canSearch {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Places")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    if let mapPins, !rows.isEmpty {
                        TrailPlacePinSwitch(controller: mapPins)
                    }
                }
                if !rows.isEmpty {
                    let photoCounts = Self.photoCounts(hike.photos)
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button { onOpen(row.id) } label: {
                                HStack(spacing: 8) {
                                    TrailPlaceRowView(row: row, photoCount: photoCounts[row.id] ?? 0)
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if row.id != rows.last?.id { Divider() }
                        }
                    }
                    // In the grouped card the statistics sit in, so a place
                    // card files its rows one way throughout.
                    .placeCardGroup()
                    .accessibilityIdentifier("hike-places")
                }
                if let search, canSearch {
                    Button("Find Places Along Trail", systemImage: "magnifyingglass") {
                        isSearching = true
                    }
                    .sectionActionButtonStyle()
                    .accessibilityIdentifier("hike-place-search")
                    .sheet(isPresented: $isSearching) {
                        HikePlaceSearchSheet(hike: hike, source: search.source, symbols: search.symbols)
                    }
                }
            }
        }
    }

    /// How many photographs each place has, counted once for every row.
    private static func photoCounts(_ photos: [HikePhoto]) -> [UUID: Int] {
        photos.reduce(into: [:]) { counts, photo in
            guard let placeID = photo.placeID else { return }
            counts[placeID, default: 0] += 1
        }
    }
}

/// The switch beside a saved hike's *Places* heading: on draws every saved
/// hike's places on the map, off takes the pins away and deletes nothing. See
/// ``TrailPlacePinController/showsPins``.
///
/// Its own view so the switch's position is read here and not by the section:
/// flipping it redraws one control rather than the list beside it.
private struct TrailPlacePinSwitch: View {
    let controller: TrailPlacePinController

    var body: some View {
        Toggle(
            "Show Places on Map",
            // A closure rather than `controller.setShowsPins` itself: handing
            // the main-actor method over as the setter makes the compiler
            // write an `@isolated(any)` reabstraction thunk, and Swift 6.3's
            // IRGen crashes emitting it — which is the compiler CodeQL still
            // builds with.
            isOn: Binding(get: { controller.showsPins }, set: { controller.setShowsPins($0) })
        )
        .labelsHidden()
        .accessibilityIdentifier("hike-place-pins-toggle")
    }
}

/// A shared hike's places, on its preview: the same rows as a saved hike's
/// section, and nothing to tap — the places are the author's until the hike
/// is saved, and saving is what copies them. See ``CommunityImport``.
struct SharedTrailPlaceSection: View {
    let places: [TrailPlace]
    let route: [RouteCoordinate]

    @ViewBuilder var body: some View {
        let rows = TrailPlaceOrder.ordered(places, along: route)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Places")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        TrailPlaceRowView(row: row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            .accessibilityIdentifier("community-hike-places")
        }
    }
}

/// One place, as a row: its glyph, what it is called, what kind of place it is
/// and how far along the trail it sits.
///
/// Shared by the maker's list and the detail screen's, because it is the same
/// row — the maker adds a swipe and a tap to it rather than a different shape.
/// The second line is the whole of what identifies an unnamed place, which is
/// the normal case; see ``TrailPlace/displayName``.
struct TrailPlaceRowView: View {
    let row: TrailPlaceRow
    /// How many photographs are filed under it, drawn when there are any.
    var photoCount = 0
    /// How much of the note to draw. Two lines in a list; all of it where a
    /// reviewer has to read every word — see ``CommunityReviewView``.
    var noteLineLimit: Int? = 2

    private var place: TrailPlace { row.place }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.systemImageName)
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(place.symbol == .caution ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayName)
                if !place.note.isEmpty {
                    Text(place.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(noteLineLimit)
                }
            }
            Spacer(minLength: 12)
            if photoCount > 0 {
                Label("\(photoCount)", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(photoCount) photos"))
            }
            if let anchor = row.anchor {
                Text(Self.length(anchor.distanceAlongRouteMeters))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        // One element rather than four, the rule every composite row here
        // follows — see ``HikeRow``.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trail-place-row")
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
