//
//  CommunityStaging.swift
//  OpenHikes
//
//  Where Community's two halves put the files they are still working on, and
//  what removes the ones nobody came back for.
//
//  Both halves already owned their own directory and deleted it on the way
//  out: a preview downloads a stranger's route and photographs into one and
//  removes it in `onDisappear`, a share stages re-encoded copies into one and
//  removes it in a `defer`. Both of those are code that has to get to *run*,
//  and the ordinary end of a long share is the system killing the app while it
//  is in the background. A kill reaches neither. Since both names are unique
//  per attempt — see ``previewDirectory(of:in:)`` and ``shareDirectory(of:)``,
//  and ``CommunityHikeView``'s `previewSession` for why they have to be —
//  nothing reuses the path either, so every orphan is a new one and no later
//  visit will ever tidy it away.
//
//  ``GPXExport/stagingDirectory`` answers exactly this for a directory of
//  exactly this shape, and this is that answer: one parent inside `tmp` so a
//  sweep can tell the app's staging apart from whatever else the system leaves
//  there, and a purge on the next piece of work that needs the parent anyway.
//  A downloaded shared hike is an exported GPX with somebody else's
//  photographs in it, and `tmp` should not end up holding every one of them.
//

import Foundation

/// The temporary directories Community writes into, and the sweep that clears
/// up the ones their owners never did.
nonisolated enum CommunityStaging {
    /// The one parent both halves stage under.
    ///
    /// Named for the feature rather than for either half, because what makes
    /// the sweep possible is that a single directory holds everything it is
    /// allowed to delete — and nothing it is not. Removing entries directly
    /// out of `tmp` by matching their names would put this code one typo away
    /// from deleting somebody else's files.
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Community", directoryHint: .isDirectory)
    }

    /// The directory one visit to one listing downloads into.
    ///
    /// Both halves of the name earn their place. The listing is there to be
    /// read by a person looking at a temporary directory and asking what left
    /// it behind; the session is what makes the name unique, and it is the
    /// half that matters, because ``CommunityHikeView/discardDownloads(at:after:)``
    /// removes whatever is at this path once the work it was handed has
    /// finished. Two visits sharing a name is the first visit's discard taking
    /// the second visit's photographs — see ``CommunityHikeView``'s header.
    static func previewDirectory(of listing: CommunityListing, in session: UUID) -> URL {
        directory.appending(
            path: "CommunityHike-\(listing.id)-\(session.uuidString)",
            directoryHint: .isDirectory
        )
    }

    /// The directory one attempt to share one hike stages into.
    ///
    /// One per *attempt*, not per hike. Two shares can be in flight at once —
    /// a re-share started while the first upload is still running, which the
    /// form deliberately allows — and a name that only carried the hike would
    /// stage both into one directory under the same file names. The second
    /// writer would then decide what the first one uploaded, since an atomic
    /// write makes a file whole rather than private.
    ///
    /// - Parameter attempt: Unique to this share. Defaulted rather than
    ///   demanded because there is exactly one right value and a caller
    ///   passing its own is a suite proving the name is stable.
    static func shareDirectory(of hikeID: UUID, attempt: UUID = UUID()) -> URL {
        directory.appending(
            path: "CommunityShare-\(hikeID.uuidString)-\(attempt.uuidString)",
            directoryHint: .isDirectory
        )
    }

    /// The directory one attempt to contribute one hike's photographs stages
    /// into.
    ///
    /// Its own name rather than ``shareDirectory(of:attempt:)`` with a second
    /// kind of caller, and the reason is the one names have to earn here:
    /// these directories outlive their owners on a kill, and the only person
    /// who ever reads one is somebody looking at `tmp` asking what left it
    /// behind. A contribution and a share are two different uploads of two
    /// different things.
    ///
    /// Unique per *attempt* for the reason a share's is, and the form allows
    /// the same second send.
    static func contributionDirectory(of hikeID: UUID, attempt: UUID = UUID()) -> URL {
        directory.appending(
            path: "CommunityPhotos-\(hikeID.uuidString)-\(attempt.uuidString)",
            directoryHint: .isDirectory
        )
    }

    /// How long an entry is left alone before a later preview or share removes
    /// it.
    ///
    /// Six times ``GPXExport``'s hour, and the asymmetry is the argument. What
    /// a lifetime that is too long costs is space in a directory the system
    /// reclaims on its own. What one that is too short costs is the
    /// photographs of the hike somebody is looking at *right now*: a sweep
    /// runs when the next preview opens, a preview can be opened while an
    /// earlier one is still downloading behind it, and an entry is judged by
    /// when it was last written rather than by whether anything still holds
    /// it. So this has to outlast a download over the worst connection a
    /// hiker will wait through — which is a longer wait than the seconds a
    /// share sheet spends copying a file out.
    private static let lifetime: TimeInterval = 6 * 3600

    /// Removes everything staged before `cutoff`.
    ///
    /// The name Community's callers know the sweep by, and this feature's own
    /// rule about *when* — see ``lifetime``, which is six times the one an
    /// export gets and says why. The pass itself is
    /// ``StagedFiles/purge(in:before:)``, which ``GPXExport`` shares.
    static func purgeAbandoned(in parent: URL, before cutoff: Date) {
        StagedFiles.purge(in: parent, before: cutoff)
    }

    /// The photographs one upload carries, re-encoded into `directory`.
    ///
    /// Both halves of publishing stage a set of pictures exactly this way — a
    /// hike's own share and a contribution onto somebody else's trail — and
    /// the invariant they keep is the reason it is one function rather than
    /// two that look alike.
    ///
    /// **The three arrays describe each other, index for index.** A photograph
    /// that will not encode — or whose file is on the device it was added on —
    /// is *dropped* rather than failing the upload: one unreadable file should
    /// cost its own picture and not the walk. So the pin and the id are
    /// appended only alongside a file that really exists, and never beside the
    /// row that was asked for. See ``CommunityHikeDetail/isConsistent``, which
    /// is what checks the pair at the other end, and
    /// ``HikePhoto/sentToCommunityAt``, which is what the ids get stamped on —
    /// a picture that would not encode did not go, and must not be recorded as
    /// though it had.
    ///
    /// The file names are positional, so a caller must not reorder afterwards.
    ///
    /// - Parameter places: The ids of the places going with this upload. A
    ///   photograph filed under one of them says so in its pin; any other
    ///   ``HikePhoto/placeID`` is left behind. Empty for a contribution to
    ///   somebody else's trail, whose places are not the contributor's.
    /// - Returns: The pins, the files and the ids, in upload order.
    static func stagePhotos(
        _ photos: [HikePhoto],
        into directory: URL,
        store: HikePhotoStore,
        places: Set<UUID> = []
    ) -> StagedPhotos {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var staged = StagedPhotos()
        for (index, photo) in photos.enumerated() {
            guard let url = store.exportCopy(
                of: photo,
                maxPixelSize: CommunityPublisher.photoMaxPixelSize,
                quality: CommunityPublisher.photoQuality,
                named: "photo-\(index).jpeg",
                into: directory
            ) else { continue }
            staged.fileURLs.append(url)
            staged.pins.append(
                CommunityPhotoPin(
                    capturedAt: photo.capturedAt,
                    coordinate: photo.coordinate,
                    placeID: photo.placeID.flatMap { places.contains($0) ? $0 : nil }
                )
            )
            staged.photoIDs.append(photo.id)
        }
        return staged
    }

    /// Removes everything an attempt staged, whatever happened.
    ///
    /// Fire-and-forget and off the main actor, in the shape the photo and tile
    /// deletions already use: what is left behind on a kill is wasted space in
    /// a temporary directory the system reclaims on its own — and which
    /// ``sweep()`` above collects anyway — which is the cheapest failure
    /// either publisher has.
    static func discard(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The ordinary call: sweep the staging parent on the way into work that
    /// is about to stage something of its own.
    ///
    /// Detached and fire-and-forget, in the shape the photo and tile deletions
    /// already use. Housekeeping must not sit in front of the fetch a hiker is
    /// waiting on, and it must not touch the thread drawing the screen — the
    /// directory listing is I/O and the number of entries is however many
    /// previews and shares a kill has left behind.
    static func sweep() {
        Task.detached(priority: .utility) {
            purgeAbandoned(in: directory, before: .now - lifetime)
        }
    }
}

/// What one pass of ``CommunityStaging/stagePhotos(_:into:store:places:)`` wrote.
///
/// Three arrays that describe each other index for index — a pin, a file and
/// the row it came from — and never the photographs that were asked for. See
/// that method for why the distinction is the whole point.
///
/// Not a draft and deliberately not near one: ``CommunitySubmissionDraft`` and
/// ``CommunityPhotoDraft`` are the payloads, and every field on one is a field
/// ``CommunityShareDisclosure`` has to account for.
nonisolated struct StagedPhotos: Sendable {
    var pins: [CommunityPhotoPin] = []
    var fileURLs: [URL] = []
    var photoIDs: [UUID] = []
}
