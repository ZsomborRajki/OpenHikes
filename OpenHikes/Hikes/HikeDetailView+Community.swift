//
//  HikeDetailView+Community.swift
//  OpenHikes
//
//  The community share control on the hike detail screen.
//
//  Split out for the reason the offline-storage helpers next door are: the
//  detail view is the largest screen in the app and the linter holds it to a
//  file length, so a subject that can stand on its own does.
//
//  The subject here is one button and the sentence it is allowed to say. See
//  ``Hike/communitySubmissionID`` for why that sentence is "shared" and never
//  "published".
//

import SwiftUI

extension HikeDetailView {
    /// Offers this hike to the community, beside the GPX export.
    ///
    /// Two share buttons rather than one menu, because they are not two ways
    /// of doing the same thing: the GPX export hands a file to whatever the
    /// hiker chooses and OpenHikes never sees it again, while this publishes
    /// to a database other people read. Folding them into one control would
    /// make the second reachable by a gesture learned for the first, and the
    /// second is the one that cannot be taken back by the person who made it.
    ///
    /// Absent rather than disabled when this launch has no transport — a
    /// hosted test or UI automation, which must not write to a real shared
    /// database. A disabled button would be a promise the launch cannot keep.
    @ViewBuilder var communityShareButton: some View {
        if let transport = communityTransport {
            Button {
                isSharingToCommunity = true
            } label: {
                Image(systemName: hike.communitySubmissionID == nil
                    ? "person.2"
                    : "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            // Says *shared*, never *published*: a submission waits for review
            // and this app cannot find out whether it passed. See
            // ``Hike/communitySubmissionID``.
            .accessibilityLabel(
                hike.communitySubmissionID == nil
                    ? "Share with the community"
                    : "Already shared with the community"
            )
            .accessibilityIdentifier("community-share-button")
            .disabled(hike.pointCount < 2)
            .sheet(isPresented: $isSharingToCommunity) {
                CommunityShareSheet(hike: hike, transport: transport)
            }
        }
    }
}
