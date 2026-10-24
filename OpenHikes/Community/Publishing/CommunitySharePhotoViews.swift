//
//  CommunitySharePhotoViews.swift
//  OpenHikes
//
//  The two pieces of body code both publishing forms share: the task that asks
//  the disk which photographs can really go, and the section a form ends on
//  once the upload has landed.
//
//  Split out of `CommunitySharePhotoTally.swift` rather than sitting beside
//  the tally, and the coverage gate is the reason. Body code is evaluated by
//  `OpenHikesUITests` alone, which CI does not run, so a file holding any of
//  it can only read as untested — which is what
//  `Scripts/coverage-exclusions.txt` exists to say, and this file is on it.
//  The tally next door is arithmetic with a suite of its own, and keeping the
//  two apart is what lets the floor go on measuring it.
//

import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI

extension View {
    /// Asks the disk which of `offered` this device holds the files of, and
    /// keeps the answer in `files`.
    ///
    /// Keyed on which photographs are offered and on nothing about which of
    /// them are ticked. The answer is about *files*, which a tap on the strip
    /// does not change, and the count, the cap and the tiles the cap holds
    /// back are all worked out from it as the choice moves — see
    /// ``CommunitySharePhotoTally`` and ``CommunitySharePhotoChoices``. So the
    /// disk is asked when the form appears, and again whenever the list
    /// changes under it. A library import still running when the form opened
    /// changes it: each picture is written to disk before its row is added,
    /// so a new row is the moment to ask. The send asks again on its way out
    /// regardless.
    ///
    /// - Parameter offered: The strip's list, as the form's `body` read it for
    ///   this pass. The same array the strip and the tally are handed, so the
    ///   key costs a pass over the ids rather than another sort.
    func findsPhotosOnThisDevice(
        among offered: [HikePhoto],
        store: HikePhotoStore,
        into files: Binding<CommunityPhotoFiles>
    ) -> some View {
        task(id: offered.map(\.id)) {
            let here = await CommunityPublisher.photosOnThisDevice(among: offered, store: store)
            // A newer list replaced this one while the disk was being asked.
            // Its own lookup is the answer to keep, and this one landing after
            // it would drop the pictures that list added.
            guard !Task.isCancelled else { return }
            files.wrappedValue = .answered(here)
        }
    }
}

/// What a publishing form shows once the upload has landed.
///
/// Both forms end here and ended it identically — the same paperplane, the
/// same *Sent for review*, the same spacing and the same one combined
/// accessibility element. What differs is the sentence underneath, because one
/// is about a hike appearing and the other about photographs appearing on
/// somebody else's, and the identifier, which is asserted per screen.
struct CommunitySentSection: View {
    /// What happens next, in this form's own words.
    let detail: LocalizedStringKey
    let identifier: String

    var body: some View {
        CommunityOutcomeSection(
            symbol: "paperplane.fill",
            tint: AnyShapeStyle(.tint),
            headline: Text("Sent for review"),
            detail: Text(detail),
            identifier: identifier,
            moment: .outcomeSucceeded
        )
    }
}
