//
//  CommunitySharePhotoStrip.swift
//  OpenHikes
//
//  The row of the hiker's own photographs, each one a tap away from being left
//  out, drawn by both screens that send pictures anywhere.
//
//  Split out when the second of those screens arrived, and it is the split
//  this repository already makes elsewhere for the same reason — the half that
//  *draws* takes the value it draws, and the half that reads a `Hike` stays on
//  the screen that has one. See ``TrailSurfaceSection`` beside
//  ``HikeSurfaceSection``, and ``ElevationChartView`` beside
//  ``HikeElevationChart``.
//
//  It earns the split twice over here, because what the two screens must agree
//  about is not the pixels but the **rules**:
//
//  - everything is included to begin with, since sending a walk sends its
//    pictures and a strip that started empty would quietly publish hikes with
//    no photographs every time somebody did not notice it — with one
//    exception, which is the picture a previous send already carried. The
//    contribution form starts those struck off, because neither this app nor a
//    reviewer can replace a submission and a second copy would sit beside the
//    first for good. The strip's job is to *say which they are*, so the state
//    is legible rather than mysterious: see ``HikePhoto/sentToCommunityAt``;
//  - a struck-off tile stays in the strip, faded, because a tile that vanished
//    would take its own undo with it — the same gesture
//    ``CommunityReviewView``'s photo section gives a reviewer, deliberately,
//    so that what a hiker does before sending and what a reviewer does before
//    publishing are one interaction rather than two;
//  - the order is ``CommunityPublisher/shareablePhotos(of:)``'s rather than the
//    gallery's, so the tiles are in the order the upload will take them and
//    the ones that fit under the cap are the first ones here.
//
//  Two spellings of any of those is how the two screens end up meaning
//  different things by the same tap.
//

import SwiftUI

/// The photographs a hiker is about to send, and which of them are going.
struct CommunitySharePhotoStrip: View {
    /// How far a struck-off picture fades. Faded rather than removed, so the
    /// tap that took it out is the tap that puts it back.
    private static let excludedTileOpacity: Double = 0.4

    /// Every picture the form offers, including the ones struck off — which
    /// still have to be drawn so they can be put back.
    let photos: [HikePhoto]
    /// Which of them are out, by id. Held by id rather than by index because
    /// the list is re-derived on every pass and an index would follow whatever
    /// moved into that slot.
    @Binding var excluded: Set<UUID>
    /// Where the photo files are.
    var store: HikePhotoStore = .shared
    /// Whether the form is mid-send, which is the one state the strip does not
    /// take taps in.
    var isSending = false

    var body: some View {
        if !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy for the reason ``HikePhotoSection/gallery(_:)`` is: an eager
                // stack starts a decode for every tile at once, for a row that shows
                // a handful.
                LazyHStack(spacing: PhotoTileMetrics.spacing) {
                    ForEach(photos) { photo in
                        tile(photo)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .disabled(isSending)
        }
    }

    private func tile(_ photo: HikePhoto) -> some View {
        let isExcluded = excluded.contains(photo.id)
        return Button {
            toggle(photo)
        } label: {
            HikePhotoThumbnail(
                photo: photo,
                store: store,
                size: PhotoTileMetrics.stripTileSize,
                cornerRadius: PhotoTileMetrics.cornerRadius,
                label: Self.label(for: photo, isExcluded: isExcluded, among: photos.count)
            )
            .opacity(isExcluded ? Self.excludedTileOpacity : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isExcluded ? Color.secondary : Color.accentColor)
                    .padding(4)
                    // The tick is what the label already says, so it is
                    // decoration rather than a second thing to hear.
                    .accessibilityHidden(true)
            }
            // A fact about the photograph rather than about the choice, so it
            // is drawn whichever way the tick is pointing: a copy of this one
            // is already in the public database, and a hiker who deliberately
            // puts it back should still be able to see that.
            .overlay(alignment: .bottomLeading) {
                if photo.hasBeenSentToCommunity {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.footnote)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        // `-tile-` rather than bare `-photo-`: the count row above answers to
        // `community-share-photo-count`, and a test reaching for "the first
        // tile" by prefix would otherwise find the number instead.
        .accessibilityIdentifier(
            photo.hasBeenSentToCommunity
                ? "community-share-photo-tile-sent-\(photo.id.uuidString)"
                : "community-share-photo-tile-\(photo.id.uuidString)"
        )
    }

    /// Strikes a photograph off, or puts it back.
    private func toggle(_ photo: HikePhoto) {
        if excluded.contains(photo.id) {
            excluded.remove(photo.id)
        } else {
            excluded.insert(photo.id)
        }
    }

    /// What a tile is called, which has to carry the state as well as the
    /// place: the difference between included and struck off is drawn as a
    /// glyph and an opacity, and neither is a thing a screen reader can see.
    static func label(for photo: HikePhoto, isExcluded: Bool, among total: Int) -> String {
        let place = String(localized: "Photo, \(total) in this hike")
        guard !photo.hasBeenSentToCommunity else {
            // The state and the reason for it, because a tile struck off by
            // the form and a tile struck off by the hiker look identical and
            // mean different things — and only one of them is a thing the
            // hiker did.
            return isExcluded
                ? String(localized: "\(place), already sent, not shared again")
                : String(localized: "\(place), already sent, shared again")
        }
        return isExcluded
            ? String(localized: "\(place), not shared")
            : String(localized: "\(place), shared")
    }
}
