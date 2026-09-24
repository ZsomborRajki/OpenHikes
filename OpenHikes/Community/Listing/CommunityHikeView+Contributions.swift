//
//  CommunityHikeView+Contributions.swift
//  OpenHikes
//
//  The second fetch a shared hike makes: what other hikers have added to this
//  trail.
//
//  Split out of `CommunityHikeView.swift` for the reason
//  `HikeDetailView+Community.swift` is split out of its own screen — the
//  preview is the second-largest view in the app, the linter holds it to a
//  file length, and this is a subject that stands on its own. It is still a
//  member of ``CommunityHikeView``, inlined into its body like any other
//  method, and the render-isolation note in that file's header covers it.
//
//  The subject is one request and the three decisions around it. Each is
//  stated on the method below, because each is a decision rather than a
//  default: a failure draws nothing, blocked contributors never reach the
//  wire, and the answer is thrown away with the screen.
//
//  And the read side, which is here because it is the same subject seen from
//  the other end. The request's exclusion set covers everybody this hiker had
//  already blocked when the screen opened; ``visible(_:)`` covers the ones
//  they blocked *while it was up*, and the sets a reviewer took down, neither
//  of which can reach a request that is long finished. See
//  ``CommunityPhotoActions``, which is where both decisions are made.
//

import OpenHikesData
import os
import SwiftUI

extension CommunityHikeView {
    /// Where a failed contribution fetch goes instead of onto the screen.
    static var contributionLogger: Logger {
        Logger(subsystem: "OpenHikes", category: "Community")
    }

    /// Asks what other hikers have added to this trail, and hangs it on the
    /// detail already on screen.
    ///
    /// Three things about this are worth stating because each is a decision
    /// rather than a default.
    ///
    /// **A failure is invisible.** Nothing asked for it, the strip and the
    /// pins are already up, and a *couldn't load the contributed photos* row
    /// would be an error about an absence — a trail with no contributions and
    /// one whose contributions did not arrive look the same, and that is
    /// honest rather than evasive: neither is a thing the hiker can act on.
    ///
    /// **Blocked contributors never reach the wire.** The exclusion set goes
    /// into the request, which is where it has to go for a block to mean
    /// anything about a stranger's pictures — downloading them *is* the cost.
    /// ``CommunityBlockList`` is read here rather than filtered afterwards for
    /// that reason.
    ///
    /// **It is asked once per open and thrown away with the screen**, the rule
    /// the trail analysis on this screen already follows. There is nowhere to
    /// keep these: they are somebody else's photographs in a directory this
    /// visit owns, and a hike nobody has imported has no row to hold them on.
    func loadContributions() {
        contributionsTask = Task {
            let contributions: [CommunityPhotoContribution]
            do {
                contributions = try await transport.contributedPhotos(
                    for: listing.id,
                    excluding: blockList.blockedIDs,
                    downloadingInto: downloadDirectory
                )
            } catch {
                Self.contributionLogger.debug(
                    """
                    Could not load contributed photos: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                return
            }
            guard !Task.isCancelled, !contributions.isEmpty else { return }
            // Only onto the detail that is still on screen. A retry replaces
            // `phase`, and a fetch that landed against the previous attempt
            // would hang a stranger's pictures on a route nobody is looking
            // at — and worse, on files a re-download has already replaced.
            guard case .loaded(var detail) = phase else { return }
            detail.contributions = contributions
            withAnimation { phase = .loaded(detail) }
            // The map is told again, because its pins are the merged set: the
            // hike's own photographs went up when the route did, and these are
            // the ones that arrived afterwards. One call with the whole list
            // rather than an append, so the strip and the pins are always the
            // same answer to the same question — which is why it is the
            // filtered detail that goes, exactly as the strip draws one.
            publishPhotoPins(visible(detail))
        }
    }

    /// `detail` without the contributed sets this hiker may no longer see.
    ///
    /// Two things can hide a set after it has been downloaded, and neither can
    /// reach the request that fetched it: blocking its contributor, and — for
    /// a reviewer — taking it down. Both are decided in the gallery pushed
    /// over this screen, and coming back from that gallery is a pop rather
    /// than a fetch: ``CommunityHikeView/load()`` returns at once for a loaded
    /// phase, deliberately, because re-downloading a stranger's photographs
    /// every time somebody closes the viewer would be the cost this screen is
    /// most careful about. So the filter is on the draw.
    ///
    /// The filtering itself is ``CommunityHikeDetail/excluding(authors:contributions:)``,
    /// which is where the arithmetic it has to preserve lives and where a
    /// suite can reach it. This is the half that knows *which* sets: the block
    /// list, which is the hiker's, and the reviewer's own record of what they
    /// have removed.
    ///
    /// Nothing is thrown away — ``CommunityHikeView/phase`` keeps every set
    /// that arrived — so unblocking a contributor from Settings brings their
    /// photographs back without a second download.
    func visible(_ detail: CommunityHikeDetail) -> CommunityHikeDetail {
        detail.excluding(
            authors: blockList.blockedIDs,
            contributions: review?.takenDownContributions ?? []
        )
    }

    /// Hands the map where this hike's photographs were taken, and what a tap
    /// on one of those pins opens.
    ///
    /// One call rather than three copies of two, because the pair has to stay
    /// a pair: the pins and the gallery a pin opens are both read out of the
    /// same `detail`, so a pin can never open a page of a different picture.
    /// That is the same agreement the strip and the pins already keep, and it
    /// is why what goes in is whichever `detail` the caller is drawing —
    /// ``visible(_:)``'s answer everywhere the hiker can see it.
    func publishPhotoPins(_ detail: CommunityHikeDetail) {
        browser.previewPhotosLoaded(detail.previewPhotos, of: listing) { index in
            onOpenPhoto(detail.galleryPhotos, index)
        }
    }
}
