//
//  StagedFiles.swift
//  OpenHikes
//
//  The sweeps that clear up a staging directory nobody came back for, and the
//  deletion of one its owner lets go of.
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
//  ## Directories that last a launch
//
//  The Wikimedia Commons photographs — the maker's (``TrailDraftPhotos``) and
//  the *Community* tab's (``CommunityCommonsPhotos``) — are staged the other
//  way. Nothing either downloads can be wanted by the next launch, so instead
//  of dating entries a launch sweeps everything under its parent but the
//  directory it is already using, and while the app is running each
//  controller deletes a directory the moment it lets go of it. Naming a fresh
//  directory, that sweep and that deletion were written out in both
//  controllers, identically, and are here for the same reason the purge is.
//  Which directory is current, which is kept beside it and for how long are
//  each controller's own, and stay there.
//
//  The deletion is not only theirs: ``CommunityStaging/discard(_:)`` and a
//  saved trail's ``TrailDraftPhotoHandOff/discard()`` call it too.
//  ``CommunityHikeView/discardDownloads(at:after:)`` does not: it waits out
//  the work still reading from or writing into its directory first, and that
//  ordering is its own.
//

import Foundation

/// Names, sweeps and removes the app's staging directories in `tmp`.
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

    /// A directory inside `parent` that nothing else will be handed, named
    /// but not created — whatever writes into it first creates it.
    static func freshDirectory(in parent: URL) -> URL {
        parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Removes whatever an earlier launch left in `parent`, except `current`.
    ///
    /// `current` is the entry of `parent` this launch has already handed out,
    /// and it is spared by its name, so a directory further down would go
    /// with the entry above it. The sweep runs off the main actor, so by the
    /// time it lists `parent` a search may be writing into `current`, and it
    /// can only spare what it knows the name of. Silent about every failure,
    /// for the reason ``purge(in:before:)`` is.
    ///
    /// Answers the sweep, which every caller lets go and a suite waits out:
    /// what it spares is only visible once it has finished, since a sweep
    /// that deleted `current` last and one that never touched it look the
    /// same while it is still running.
    @discardableResult static func sweep(_ parent: URL, keeping current: URL) -> Task<Void, Never> {
        let kept = current.lastPathComponent
        return Task.detached(priority: .utility) {
            let manager = FileManager.default
            let left = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for url in left where url.lastPathComponent != kept {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Removes `url` and everything in it, off the main actor and
    /// fire-and-forget: a directory of photographs can be a few megabytes of
    /// thumbnails, and what a kill leaves behind is housekeeping the next
    /// sweep of its parent — or the system — does anyway. Answers the
    /// deletion, for a suite to wait out.
    @discardableResult static func remove(_ url: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
