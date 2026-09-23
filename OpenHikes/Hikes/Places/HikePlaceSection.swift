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
//  ## Read-only, and it says so by having no controls rather than by refusing
//
//  Editing the route or the places of an existing hike is out of scope — the
//  plan issue draws that line. What this screen has instead is the one thing a
//  reader wants, which is to find the place on the map.
//
//  ## Absent rather than empty
//
//  Unlike ``HikePhotoSection``, which is unconditional because it carries an
//  offer — *go and find some* — this draws nothing for a hike with no places.
//  There is nothing to offer: the only way to mark one is in the maker, this
//  screen is not the maker, and a section that said "no places" on every
//  recorded walk and every imported file would be a permanent empty shelf on
//  the commonest screen in the app.
//

import SwiftUI

struct HikePlaceSection: View {
    let hike: Hike
    /// Draws these places on the map for as long as this section is on screen.
    /// `nil` in a preview, and in a test that has no map.
    var mapPins: TrailPlacePinController?
    /// Frames one on the map. The same span a photograph's *Show on map* uses,
    /// because the question is the same one: where on the trail is this?
    var onShow: (TrailPlace) -> Void = { _ in /* no-op default */ }

    @ViewBuilder var body: some View {
        // Ordered once and handed down, the way ``HikePhotoSection`` orders
        // its photographs once: ``Hike/orderedPlaces`` projects every row and
        // sorts them against the route, and asking twice in one pass would do
        // all of it twice.
        let rows = hike.orderedPlaces
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Places")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { onShow(row.place) } label: {
                            TrailPlaceRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            .accessibilityIdentifier("hike-places")
            // The claim is on the section rather than on the screen, so the
            // pins go on the map when there are places to draw and come off
            // when the hiker leaves — see ``TrailPlacePinController``.
            .trailPlacePins(mapPins, rows: rows)
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
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
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
