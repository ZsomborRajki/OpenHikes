//
//  CommunitySharePhotoTally.swift
//  OpenHikes
//
//  How many photographs a send would really carry, and the sentence about the
//  ones it would not.
//
//  Both publishing forms ask this — ``CommunityShareSheet`` about a whole hike
//  and ``CommunityPhotoShareSheet`` about photographs going onto somebody
//  else's trail — and each had worked it out for itself, in four members with
//  the same names and the same bodies.
//
//  The forms themselves stay apart, for the reason
//  ``CommunityPhotoShareSheet``'s header gives at length: one asks for a
//  title, notes and a credit and promises what a whole hike carries, and the
//  other is sending none of that. This is not that. This is arithmetic the two
//  cannot be allowed to disagree about, because the number under the strip has
//  to be the number that goes.
//
//  ## Rows are not files
//
//  A photo row mirrors between a hiker's devices and its pixels never do, so
//  the iPad shows a full strip for a walk recorded on the phone and can send
//  none of it — and the upload drops exactly those, silently. Until the disk
//  has answered, the capped row count is the best guess available; after that
//  ``count`` is the number that will really go. The difference between the two
//  is what ``unsendableCount`` names, and what the form says out loud rather
//  than leaving a hiker to read a shrunken number as the app having lost their
//  pictures.
//
//  ## Its own file, and a suite
//
//  Out of the two forms rather than inside either, which is what lets a suite
//  reach it: both are on ``Scripts/coverage-exclusions.txt`` because their
//  executable lines are SwiftUI bodies, and a number this load-bearing should
//  not be exempt along with them. The view half of what was extracted with it
//  is in `CommunitySharePhotoViews.swift`, which *is* body code and is
//  excluded. See ``CommunitySharePhotoTallyTests``.
//
//  ## The cap is applied after the exclusions
//
//  Deliberately, and it is why ``includedCount`` is what comes in here rather
//  than a raw total: striking a picture off should let the next one *in*
//  rather than simply shorten the upload, which is the difference between
//  choosing twelve and getting whichever eleven were left over. See
//  ``CommunityPublisher/share(_:authorName:transport:excludingPhotos:store:save:)``,
//  which applies it the same way on the other side.
//

import Foundation
import SwiftData

/// What a send would carry, and what it would leave behind.
///
/// Main-actor isolated, which is the target default and is right here rather
/// than incidental: it reads a `@Model`'s photographs through
/// ``CommunityPublisher/ownPhotos(of:)``, and both callers are a `View` body.
/// It is built fresh on each read for the same reason — a stored copy would be
/// a second answer able to go stale against the rows it describes.
struct CommunitySharePhotoTally {
    /// The hiker's own photographs still ticked, before the cap and the disk
    /// have had their say.
    let includedCount: Int
    /// What the disk answered, or `nil` while it has not been asked yet.
    let sendableCount: Int?

    /// - Parameters:
    ///   - hike: The walk the photographs came from.
    ///   - excluded: The ones struck off the strip, by id.
    ///   - sendableCount: What ``CommunityPublisher/sendablePhotoCount(of:excludingPhotos:store:)``
    ///     last answered, or `nil` until it has.
    init(hike: Hike, excluding excluded: Set<UUID>, sendableCount: Int?) {
        // Counted over the hiker's *own* photographs, the same list the strip
        // draws and the upload takes: a hike saved from the community carries
        // its author's pictures too, and none of those is going anywhere. See
        // ``CommunityPublisher/ownPhotos(of:)``.
        includedCount = CommunityPublisher.ownPhotos(of: hike)
            .count(where: { !excluded.contains($0.id) })
        self.sendableCount = sendableCount
    }

    /// The number to put in front of the hiker.
    var count: Int { sendableCount ?? capped }

    /// How many of the ticked pictures are on another device, and so are not
    /// going anywhere from here. Zero until the disk has answered, because
    /// until then there is nothing to subtract.
    var unsendableCount: Int {
        guard let sendableCount else { return 0 }
        return capped - sendableCount
    }

    /// Whether the disk has answered. A form holds its Send button until it
    /// has: the count it would send on is a guess before this is true.
    var hasCounted: Bool { sendableCount != nil }

    /// Whether there is anything at all to send.
    var hasSomethingToSend: Bool { count > 0 }

    private var capped: Int { min(includedCount, CommunityPublisher.maximumPhotos) }

    /// What to say about the pictures that are staying behind.
    ///
    /// Number-neutral after the count, the rule the rest of this feature's
    /// wording follows: one photograph reads as written English rather than as
    /// a template with a 1 in it. That singular is the catalog's plural
    /// variation, not a branch here.
    static func onAnotherDevice(count: Int) -> String {
        String(
            localized: """
            \(count) of this hike's photos are on the device they were \
            added on, so they can't be shared from here.
            """
        )
    }
}
