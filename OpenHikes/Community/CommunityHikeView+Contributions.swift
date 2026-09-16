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
            // same answer to the same question.
            browser.previewPhotosLoaded(detail.previewPhotos, of: listing)
        }
    }
}
