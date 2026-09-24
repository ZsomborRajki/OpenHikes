//
//  CommunityReviewPhotoStrip.swift
//  OpenHikes
//
//  The strip of photographs a reviewer decides about, on either review
//  screen.
//
//  Struck off rather than deleted as they are tapped: nothing leaves the
//  submission until Publish, so a reviewer who hits the wrong tile puts it
//  back with the same tap. That is also why the removed ones stay in the
//  strip, faded — a tile that vanished would take its own undo with it.
//
//  Written twice until now, down to the tile, the fade, the two-number
//  header and the footer's wording. The screens around it stay different;
//  this was never one of the differences.
//
//  ## One set of identifiers
//
//  The two copies named the same elements differently —
//  `review-photo-remove` against `photo-review-remove` — and only the first
//  pair was ever asserted by a test. There is one set now, the `review-` one
//  the automation already knows, so a failure names the strip rather than
//  which screen it was drawn on. The screens are told apart by everything
//  around it.
//

import OpenHikesData
import SwiftUI

struct CommunityReviewPhotoStrip<Subject: CommunityReviewSubject>: View {
    let subject: Subject
    /// The screen's state, read for the removals and the counts and written
    /// by the tiles.
    let decisions: CommunityReviewDecisions<Subject>
    /// What to say when a set has been emptied entirely, or `nil` for a
    /// screen where that is not a dead end.
    ///
    /// On a hike, leaving every photograph out still publishes the walk. On a
    /// contribution the photographs *are* the submission, so an empty set is
    /// a decline and the screen says so rather than offering a publish that
    /// would create a record of nothing.
    var emptiedMessage: String?
    /// What to say when nothing arrived at all, or `nil` for a screen that
    /// handles that case before it gets here.
    var emptyMessage: String?
    /// Tells the map what the strip now shows.
    let showOnMap: (Subject) -> Void

    var body: some View {
        Section {
            if subject.photoFileURLs.isEmpty, let emptyMessage {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-photos-empty")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy for the reason ``HikePhotoSection/gallery(_:)`` is,
                    // and the most expensive instance of it: these tiles are
                    // `photoTileSize` across so a reviewer can actually judge
                    // a photograph, which makes each decode three times that
                    // in pixels — and an eager stack started every one of a
                    // submission's ``CommunityPublisher/maximumPhotos`` at
                    // once, for a row that shows two.
                    LazyHStack(spacing: 12) {
                        ForEach(
                            Array(subject.photoFileURLs.enumerated()),
                            id: \.offset
                        ) { index, url in
                            tile(at: index, url: url, removable: subject.hasEveryPhoto)
                        }
                    }
                }
                .accessibilityIdentifier("review-photos")
            }
        } header: {
            // Two numbers only once they differ, so the ordinary case reads
            // exactly as it did before there was anything to count twice.
            Text(
                decisions.removedPhotos.isEmpty
                    ? "Photos (\(subject.photoFileURLs.count))"
                    : "Photos (\(decisions.keptPhotoCount) of \(subject.photoFileURLs.count))"
            )
        } footer: {
            footer
        }
    }

    private func tile(at index: Int, url: URL, removable: Bool) -> some View {
        let isRemoved = decisions.removedPhotos.contains(index)
        return CommunityPhotoTile(url: url, size: Metrics.photoTileSize)
            .opacity(isRemoved ? Metrics.removedTileOpacity : 1)
            .overlay(alignment: .topTrailing) {
                if removable {
                    Button {
                        decisions.toggleRemoval(of: index, thenShowing: showOnMap)
                    } label: {
                        Image(
                            systemName: isRemoved
                                ? "arrow.uturn.backward.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isRemoved ? Color.accentColor : Color.red)
                    }
                    // `.borderless` rather than `.plain`: a `Form` row holding
                    // a single plain button hands the whole row's taps to it,
                    // and this row is a scrollable strip of several.
                    .buttonStyle(.borderless)
                    .padding(8)
                    .disabled(decisions.isDeciding)
                    .accessibilityLabel(
                        isRemoved
                            ? Text("Keep photo \(index + 1)")
                            : Text("Leave photo \(index + 1) out")
                    )
                    .accessibilityIdentifier(
                        isRemoved ? "review-photo-restore" : "review-photo-remove"
                    )
                }
            }
    }

    /// What the strip needs saying about it, in the order it matters.
    @ViewBuilder private var footer: some View {
        if !subject.hasEveryPhoto, !subject.photoFileURLs.isEmpty {
            // The one state where removal is withheld, and it is withheld
            // rather than risked: publishing rebuilds the record's
            // photographs out of the copies on this device, so doing it with
            // one missing would delete that one as well — a photograph nobody
            // decided anything about, gone for good.
            Text(
                CommunityPublishedPhotos.incompleteDownload(
                    missing: subject.photosOnRecord - subject.photoFileURLs.count
                )
            )
            .accessibilityIdentifier("review-photos-incomplete")
        } else if decisions.removedPhotos.isEmpty {
            Text("Leave out any photo that shouldn't be published. The rest still go.")
        } else if decisions.keptPhotoCount == 0, let emptiedMessage {
            // Not a warning about a removal but a description of what the
            // screen has become.
            Text(emptiedMessage)
                .accessibilityIdentifier("review-photos-emptied")
        } else {
            // Said plainly because it is the only irreversible thing on these
            // screens short of declining, and because the strip above is
            // still showing the pictures it is about.
            Text(CommunityPublishedPhotos.removalWarning(count: decisions.removedPhotos.count))
                .accessibilityIdentifier("review-photos-removed")
        }
    }
}

/// A plain enum because the strip is generic, and a generic type cannot hold
/// a stored static property — while a computed one would put the literal back
/// at the point of use.
private enum Metrics {
    /// Tiles big enough to judge a photograph by rather than to recognise
    /// one. Larger than ``CommunityHikeView``'s, and that difference is the
    /// whole argument of these screens in one number: there, a strip of
    /// thumbnails says *this hike has photographs*; here, the photograph
    /// **is** the thing being decided about.
    static let photoTileSize: CGFloat = 220
    /// How faint a photograph goes once it has been struck off.
    ///
    /// Still legible on purpose. The tile is the only handle for putting it
    /// back, and a reviewer who removed the wrong one has to be able to see
    /// which one they removed.
    static let removedTileOpacity: Double = 0.3
}
