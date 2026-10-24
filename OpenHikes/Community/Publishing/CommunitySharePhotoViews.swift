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
    /// Asks the disk which of `hike`'s own photographs this device holds the
    /// files of, and keeps the answer in `files`.
    ///
    /// Asked once, when the form appears, and not again as the hiker strikes
    /// pictures off: the answer is about *files*, which a tap on the strip
    /// does not change, and the count, the cap and the tiles the cap holds
    /// back are all worked out from it as the choice moves — see
    /// ``CommunitySharePhotoTally`` and ``CommunitySharePhotoChoices``.
    /// Nothing else can change it while the form is the screen on top, and
    /// the send asks again on its way out regardless.
    func findsPhotosOnThisDevice(
        of hike: Hike,
        store: HikePhotoStore,
        into files: Binding<CommunityPhotoFiles>
    ) -> some View {
        task(id: hike.id) {
            let here = await CommunityPublisher.photosOnThisDevice(
                among: CommunityPublisher.ownPhotos(of: hike),
                store: store
            )
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
