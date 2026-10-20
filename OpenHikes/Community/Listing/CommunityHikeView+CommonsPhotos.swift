//
//  CommunityHikeView+CommonsPhotos.swift
//  OpenHikes
//
//  The third fetch a curated route's preview makes: what Wikimedia Commons
//  has along it.
//
//  Split from `CommunityHikeView.swift` for length, the way the contributions
//  fetch is, which is why the state it reads is `internal` rather than
//  `private`. Its three decisions are the contributions fetch's three, for the
//  same reasons — a failure draws nothing, the answer goes with the screen,
//  and nothing waits for it but the import — and one more of its own: the
//  photographs are credited where they are shown, because the licence they
//  came under is the only reason the app may show them. See ``CommonsPhoto``.
//

import OpenHikesData
import os
import SwiftUI

extension CommunityHikeView {
    /// Where a failed Commons fetch goes instead of onto the screen.
    static var commonsLogger: Logger {
        Logger(subsystem: "OpenHikes", category: "Community")
    }

    /// Asks Commons for the photographs taken along `route`, and hangs them on
    /// the detail already on screen.
    ///
    /// Only for a route from OpenStreetMap; a published hike carries the
    /// photographs its author took, and the transport answers it with none
    /// anyway — see ``MergedCommunityTransport/commonsPhotos(for:along:downloadingInto:)``.
    /// Asked here rather than as well, so a published hike's preview starts no
    /// task at all.
    ///
    /// **A failure is invisible**, for the reason a contributions failure is:
    /// a route with no photographs on Commons and one whose photographs did
    /// not arrive look the same, and neither is a thing the hiker can act on.
    func loadCommonsPhotos(along route: [RouteCoordinate]) {
        guard listing.isCurated else { return }
        commonsTask = Task {
            let photos: [CommonsPhoto]
            do {
                photos = try await transport.commonsPhotos(
                    for: listing,
                    along: route,
                    downloadingInto: downloadDirectory
                )
            } catch {
                Self.commonsLogger.debug(
                    "Could not load Commons photos: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            guard !Task.isCancelled, !photos.isEmpty else { return }
            // Onto the detail on screen now, for the reason the contributions
            // are: a retry replaces `phase`, and the contributions may have
            // landed on it while these were on their way.
            guard case .loaded(var detail) = phase else { return }
            detail.commonsPhotos = photos
            withAnimation { phase = .loaded(detail) }
            // The whole merged set again, so the map's pins and the strip are
            // one answer — see ``publishPhotoPins(_:)``.
            publishPhotoPins(visible(detail))
        }
    }

    /// Whose photographs these are, under the strip that shows them.
    ///
    /// One sentence for the set, because each picture's own credit is on its
    /// page in the gallery — who took it, its licence, and a link to both —
    /// and a strip of 96-point tiles has no room for twelve of them. Drawn
    /// only when there is a Commons photograph in the strip, for the reason
    /// ``curatedAttribution`` is drawn only for a curated route: a credit for
    /// nothing credits nothing.
    @ViewBuilder
    func commonsAttribution(_ detail: CommunityHikeDetail) -> some View {
        if !detail.commonsPhotos.isEmpty {
            Text("Photos from Wikimedia Commons, each under its own license. Open one to see who took it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("community-commons-attribution")
        }
    }
}
