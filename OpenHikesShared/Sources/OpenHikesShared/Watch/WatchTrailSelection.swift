//
//  WatchTrailSelection.swift
//  OpenHikesShared
//
//  Which arriving trail the watch takes, and which it drops.
//
//  ## Why a package can arrive that nobody wants
//
//  The phone answers each trail request with a task of its own, and the watch
//  cancelling a request reaches only the transfer still queued on its side —
//  an answer the phone is already packaging, or already sending, crosses
//  anyway. So a hiker who opens trail A and then trail B before A has landed
//  can be sent B and then A. Taking every arrival as the current trail put A
//  under B's screen, which matches on the hike, fell back to "Fetching this
//  trail…" and stayed there: B had arrived, and nothing would ask for it
//  again. The shared tracker and the copy on disk were A's.
//
//  One trail asked for twice has the same race — a tap and a new library
//  digest either side of an edit on the phone — and there the late answer is
//  the route as it was before the edit.
//
//  ## Why it is here
//
//  The watch has no test bundle. `WatchModel` keeps one of these, tells it
//  which trail the hiker opened and asks it before replacing anything, so the
//  whole decision runs on the host.
//

import Foundation

/// The trail the hiker last asked the watch for, and what that rules out.
public struct WatchTrailSelection: Equatable, Sendable {
    /// The trail the hiker last opened, or `nil` before they have opened one
    /// in this process.
    ///
    /// Not persisted. A package that lands after a relaunch is an answer to a
    /// request the last process made, which is the last thing the hiker asked
    /// for, and a watch that refused it would be waiting for a screen to be
    /// opened again before it drew anything.
    public private(set) var wantedHikeID: UUID?

    public init(wantedHikeID: UUID? = nil) {
        self.wantedHikeID = wantedHikeID
    }

    /// The hiker opened `hikeID`; a package for any other trail is now late.
    public mutating func select(_ hikeID: UUID) {
        wantedHikeID = hikeID
    }

    /// Whether `package` should replace `held` as the trail the watch draws,
    /// matches against and keeps on disk.
    ///
    /// Two ways to be late. A package for a trail other than the one wanted
    /// answers a request the hiker has since moved on from. A package for the
    /// trail already held, packaged *before* the copy held was, is that trail
    /// as it stood before an edit — ``WatchTrailPackage/sentAt`` is when the
    /// phone read the route, so it orders the two. The same moment is taken:
    /// it is the same read, or one no older.
    public func accepts(_ package: WatchTrailPackage, replacing held: WatchTrailPackage?) -> Bool {
        if let wantedHikeID, package.hikeID != wantedHikeID { return false }
        guard let held, held.hikeID == package.hikeID else { return true }
        return package.sentAt >= held.sentAt
    }

    /// Which trail to ask about again now that `digest` has landed, if any.
    ///
    /// The wanted one when there is one, rather than the one held: asking
    /// cancels every trail request still queued, so re-asking for the held
    /// trail while another is on its way would withdraw the request the
    /// hiker's screen is waiting on. A trail no longer on the list is not
    /// asked about — it may have been deleted, and a hiker following it still
    /// has the line.
    public func refreshTarget(holding held: WatchTrailPackage?, in digest: WatchLibraryDigest) -> UUID? {
        guard let hikeID = wantedHikeID ?? held?.hikeID,
              digest.hikes.contains(where: { $0.id == hikeID })
        else { return nil }
        return hikeID
    }
}
