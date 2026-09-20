//
//  CommunitySharePhotoViews.swift
//  OpenHikes
//
//  The two pieces of body code both publishing forms share: the task that asks
//  the disk how many photographs can really go, and the section a form ends on
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

import SwiftData
import SwiftUI

extension View {
    /// Keeps `count` up to date with what this device can actually send.
    ///
    /// Re-asked whenever the hiker strikes a photograph off or puts one back,
    /// because the answer is about a particular set of *files*: the count
    /// under the strip has to be what will really go, and the cap means taking
    /// one out can let another in. Nothing else can change it while the form
    /// is the screen on top.
    func countsSendablePhotos(
        of hike: Hike,
        excluding excluded: Set<UUID>,
        store: HikePhotoStore,
        into count: Binding<Int?>
    ) -> some View {
        task(id: excluded) {
            count.wrappedValue = await CommunityPublisher.sendablePhotoCount(
                of: hike,
                excludingPhotos: excluded,
                store: store
            )
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
            identifier: identifier
        )
    }
}
