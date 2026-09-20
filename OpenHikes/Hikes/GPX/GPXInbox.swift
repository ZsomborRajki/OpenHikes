//
//  GPXInbox.swift
//  OpenHikes
//
//  Cleanup for files the system copies into the app rather than opening in
//  place. Declaring a document type is what makes OpenHikes appear in the
//  Files app's "Open With" list, and it also opts the app into deliveries it
//  can't open in place — AirDrop, a mail attachment, some share extensions.
//  Those arrive as a copy in `Documents/Inbox`, which nothing ever empties, so
//  every import that came through it has to remove its own copy or the
//  container grows a duplicate of every GPX file the user ever opened.
//

import Foundation

nonisolated enum GPXInbox {
    /// The system's drop-off directory for copied documents.
    ///
    /// `nil` only if the container has no Documents directory, which would
    /// mean nothing was ever copied here either.
    static var directory: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Whether `url` names a file the system copied in, as opposed to one the
    /// document picker or Files handed over in place.
    ///
    /// A picked file lives wherever the user keeps it and must be left alone;
    /// only a copy inside `inbox` belongs to the app. Both sides are resolved
    /// and compared as paths, since the same directory reaches us as `/var` in
    /// one form and `/private/var` in the other, and with or without the
    /// trailing slash a directory URL carries.
    static func isCopy(_ url: URL, inbox: URL?) -> Bool {
        guard url.isFileURL, let inbox else { return false }
        let parent = url.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        return parent == inbox.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Removes a copied file once the import that read it has finished.
    ///
    /// Deliberately silent about failure: the file has already become a hike
    /// (or already failed to), and a copy that outlives its import is a
    /// housekeeping problem rather than something to interrupt anyone over.
    @concurrent
    static func discardCopy(at url: URL) async {
        assertOffMainThread(
            "Removing an imported copy touches the file system"
        )
        guard isCopy(url, inbox: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
