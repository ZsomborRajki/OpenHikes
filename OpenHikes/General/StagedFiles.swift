//
//  StagedFiles.swift
//  OpenHikes
//
//  The sweep that clears up a staging directory nobody came back for.
//
//  Three features write files into `tmp` and mean to remove them afterwards —
//  a GPX export, a hike archive, and Community's downloads and uploads — and
//  every one of them removes its own on a path that has to *run*. The ordinary
//  end of a long share or a long download is the system killing the app while
//  it is in the background, which reaches none of them. So each of the three
//  sweeps its parent on the way into the next piece of work that needs it
//  anyway, and this is the pass they share.
//
//  It was written twice before this file existed, once in ``GPXExport`` and
//  once in ``CommunityStaging``, with the second citing the first. The two
//  bodies were identical; what differs between the callers is the parent and
//  the lifetime, and both of those are arguments. The policy the two owners
//  keep is *which* directory and *how long*, and those stay where they are.
//

import Foundation
import OpenHikesData

/// Removes the entries of a staging directory that are older than a cutoff.
nonisolated enum StagedFiles {
    /// Removes everything in `parent` last written before `cutoff`.
    ///
    /// Dated rather than emptied wholesale: an entry written a moment ago
    /// belongs to work that is still happening — a file still being copied out
    /// of a share sheet, a preview still downloading behind the one on screen.
    /// An entry is judged by when it was last written and never by whether
    /// anything still holds it, which is what makes the caller's lifetime the
    /// thing that has to outlast its own slowest piece of work.
    ///
    /// Silent about every failure, for the reason ``GPXInbox/discardCopy(at:)``
    /// is: staging that outlives its owner is housekeeping, and nothing here
    /// should fail a share or blank a preview. A `parent` that does not exist
    /// yet is the ordinary first call and not an error.
    ///
    /// Synchronous and taking both its inputs, so a suite can age an entry and
    /// watch — what this decides is invisible in the result otherwise, since a
    /// sweep that spared a live download and one that never looked both leave
    /// a working directory in place on a good day.
    static func purge(in parent: URL, before cutoff: Date) {
        let manager = FileManager.default
        let staged = (try? manager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in staged {
            let modified = try? url
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
