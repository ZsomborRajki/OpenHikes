//
//  WatchStoredFile.swift
//  OpenHikesShared
//
//  The watch's own copies of what the phone sent it, read back off its disk.
//
//  ## The same contract as the link
//
//  A payload reaches `WatchStore` through ``WatchLink``, which refuses any
//  format but the current one, and is written to disk as the same JSON. Read
//  back with a plain decode, the file skipped that check: a watch moved to an
//  older or newer build than the one that wrote it handed a library or a
//  trail in another format to the screen on launch, and its queued walks were
//  offered to a phone that would refuse them. So a file is held to exactly
//  the check the link applies (``SharedPayload/decodeCurrentFormat(from:)``),
//  and a refusal reads as no file at all — the empty state a first launch
//  draws, until the phone sends the list or the trail again.
//
//  The queued walks are read by ``WatchWalkQueue`` itself, with the same
//  check, and a refused one is kept rather than deleted: unlike the library
//  and the trail, it may be the only copy of a recording.
//
//  Typed rather than generic for the reason ``WatchLink`` gives: it is what
//  keeps ``SharedPayload`` internal to this package.
//

import Foundation

/// Reads the watch's own cached copies, in the one format this build writes.
public enum WatchStoredFile {
    /// The trails the phone last sent.
    public static func libraryDigest(from data: Data) throws(SharedPayloadReadFailure) -> WatchLibraryDigest {
        try WatchLibraryDigest.decodeCurrentFormat(from: data)
    }

    /// The trail the watch was last handed.
    public static func trailPackage(from data: Data) throws(SharedPayloadReadFailure) -> WatchTrailPackage {
        try WatchTrailPackage.decodeCurrentFormat(from: data)
    }
}
