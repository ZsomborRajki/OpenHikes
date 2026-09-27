//
//  CommunityPhotoCopy.swift
//  OpenHikes
//
//  What copying a community hike's photographs into the saved copy came to.
//
//  The import commits the route first and copies the photographs after, one
//  at a time, and a photograph that will not copy costs itself rather than the
//  walk — see ``CommunityImport``. That bargain is only fair if the hiker is
//  told. A save that kept none of eight photographs used to come back as an
//  ordinary success, and saving the trail again answered *already in your
//  list* without trying the missing ones, so one transient failure became a
//  permanent hole in the saved hike.
//
//  So the copy is a value the preview keeps: what landed, what did not, and
//  the one thing a second attempt needs that the first had to itself — which
//  of the saved hike's places each of the author's became.
//

import Foundation

/// The photographs of one community hike that are on the saved copy, and the
/// ones that did not make it.
nonisolated struct CommunityPhotoCopy: Equatable, Sendable {
    /// One photograph of a shared trail: which set it is in, and where in that
    /// set.
    ///
    /// By position rather than by anything about the picture, because a
    /// position is what cannot collide: a hiker photographs the same summit
    /// twice, in the same minute, and a coordinate and a time cannot tell those
    /// two apart. It is only ever compared against the same detail it was read
    /// from — the preview holding both — so a set renumbered on the server
    /// between the two attempts is not a case this has to meet.
    struct Source: Hashable, Sendable {
        /// `nil` for the author's own submission, and a contribution's
        /// ``CommunityPhotoContribution/id`` for somebody else's set.
        let contributionID: String?
        let index: Int
    }

    /// On the saved hike, from this attempt or an earlier one.
    ///
    /// What makes a retry safe to offer: it tries only what is not in here, so
    /// no photograph is copied twice, and one the hiker removed from the saved
    /// hike in the meantime stays removed.
    private(set) var copied: Set<Source> = []

    /// Tried, and not on the saved hike: a file that would not read, bytes that
    /// were not an image, or a save the store refused.
    ///
    /// Not a set whose pins and files disagree. That set is left out on
    /// purpose — see ``CommunityHikeDetail/isConsistent`` — and would be left
    /// out by every retry too, so counting it here would offer the hiker a
    /// button that can never work.
    private(set) var failed: Set<Source> = []

    /// The author's place ids, to the ids the saved hike's copies of those
    /// places were given.
    ///
    /// Carried because a retry cannot work it out again: the copies were made
    /// under fresh ids — see ``CommunityImport`` — and a photograph filed
    /// under the wrong place, or none, on the second attempt would be exactly
    /// the kind of loss the retry exists to undo.
    let places: [UUID: UUID]

    init(places: [UUID: UUID]) {
        self.places = places
    }

    var isComplete: Bool { failed.isEmpty }

    /// A fresh attempt at what is still missing: what is copied stays copied,
    /// and every failure is tried again.
    func retrying() -> Self {
        var next = self
        next.failed = []
        return next
    }

    /// One photograph still to copy: where it is recorded, its pin and its
    /// file.
    typealias Pending = (source: Source, pin: CommunityPhotoPin, url: URL)

    /// The photographs of one set that are not on the hike yet, each under
    /// the source it is recorded by.
    ///
    /// Numbered before anything is left out, so a photograph keeps its
    /// position whichever of those before it have already landed.
    ///
    /// - Parameter contributionID: `nil` for the author's own submission.
    func pending(
        _ photos: some Sequence<(CommunityPhotoPin, URL)>,
        from contributionID: String?
    ) -> [Pending] {
        photos.enumerated().compactMap { index, photo in
            let source = Source(contributionID: contributionID, index: index)
            return copied.contains(source) ? nil : (source, photo.0, photo.1)
        }
    }

    /// Records one set's attempt: what `landed` is on the hike, and every
    /// other photograph that was tried failed.
    mutating func attempted(_ photos: [Pending], landed: Set<Source>) {
        for (source, _, _) in photos {
            if landed.contains(source) {
                failed.remove(source)
                copied.insert(source)
            } else {
                failed.insert(source)
            }
        }
    }
}
