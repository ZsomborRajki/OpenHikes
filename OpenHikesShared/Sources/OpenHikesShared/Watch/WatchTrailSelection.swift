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
//  the route as it was before the edit. The latest request may need no
//  answer at all because the watch already holds its revision, so read
//  timestamps alone cannot supersede an earlier answer. Every request has
//  an identity the phone echoes in its package.
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
    /// The trail the hiker last opened, or the one last taken, or `nil` before
    /// either has happened in this process.
    ///
    /// Not persisted. A package that lands after a relaunch is an answer to a
    /// request the last process made, which is the last thing the hiker asked
    /// for, and a watch that refused it would be waiting for a screen to be
    /// opened again before it drew anything. That is also why a refresh does
    /// not set it: every launch re-reads the library the phone last published,
    /// and the refresh that follows would otherwise rule that package out.
    public private(set) var wantedHikeID: UUID?

    /// The last request sent, whether the hiker opened a trail or a new
    /// library re-asked about one. An answer to an earlier request for the
    /// same trail is late.
    private var latestRequest: WatchTrailRequest?

    public init() {
        wantedHikeID = nil
        latestRequest = nil
    }

    /// The hiker opened `hikeID`: a package for any other trail is now late,
    /// and so is an answer to any earlier request for this one. Send the
    /// returned request unchanged.
    @discardableResult public mutating func select(
        _ hikeID: UUID,
        holding held: WatchTrailPackage? = nil
    ) -> WatchTrailRequest {
        wantedHikeID = hikeID
        return ask(hikeID, holding: held)
    }

    /// Asks about `hikeID` again because a new library landed — see
    /// ``refreshTarget(holding:in:)``. Supersedes earlier answers for that
    /// trail like ``select(_:holding:)``, but is not the hiker choosing it.
    /// Send the returned request unchanged.
    public mutating func refresh(_ hikeID: UUID, holding held: WatchTrailPackage?) -> WatchTrailRequest {
        ask(hikeID, holding: held)
    }

    /// Whether `package` should replace `held` as the trail the watch draws,
    /// matches against and keeps on disk. Tell ``took(_:)`` when it does.
    ///
    /// A package for a trail other than the one wanted answers a request the
    /// hiker has since moved on from. A package answering an earlier request
    /// for the trail last asked about is late too, even when the latest
    /// request needs no reply because the watch already holds the phone's
    /// revision. The read timestamp also orders two copies of the trail
    /// already held, which covers arrivals after a relaunch before a request
    /// has been made — ``WatchTrailPackage/sentAt`` is when the phone read
    /// the route. The same moment is taken: it is the same read, or one no
    /// older.
    public func accepts(_ package: WatchTrailPackage, replacing held: WatchTrailPackage?) -> Bool {
        if let wantedHikeID, package.hikeID != wantedHikeID { return false }
        if let latestRequest, package.hikeID == latestRequest.hikeID, package.requestID != latestRequest.id {
            return false
        }
        guard let held, held.hikeID == package.hikeID else { return true }
        return package.sentAt >= held.sentAt
    }

    /// The watch took `package`, so it is the trail wanted until the hiker
    /// opens another. Only changes anything after a relaunch, where a
    /// package answering the last process's request is taken with nothing
    /// wanted yet — and the answer to the launch's refresh of the trail held
    /// before it must not replace it.
    public mutating func took(_ package: WatchTrailPackage) {
        wantedHikeID = package.hikeID
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

    private mutating func ask(_ hikeID: UUID, holding held: WatchTrailPackage?) -> WatchTrailRequest {
        let request = WatchTrailRequest(hikeID: hikeID, holding: held)
        latestRequest = request
        return request
    }
}
