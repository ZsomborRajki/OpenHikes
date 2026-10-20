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
    /// The trail last requested, or `nil` before this process has asked for one.
    ///
    /// Not persisted. A package that lands after a relaunch is an answer to a
    /// request the last process made, which is the last thing the hiker asked
    /// for, and a watch that refused it would be waiting for a screen to be
    /// opened again before it drew anything.
    public var wantedHikeID: UUID? { latestRequest?.hikeID }

    private var latestRequest: WatchTrailRequest?

    public init() {
        latestRequest = nil
    }

    /// Asks for `hikeID`, superseding every earlier request, including a
    /// refresh of the same trail. Send the returned request unchanged.
    @discardableResult public mutating func select(
        _ hikeID: UUID,
        holding held: WatchTrailPackage? = nil
    ) -> WatchTrailRequest {
        let request = WatchTrailRequest(hikeID: hikeID, holding: held)
        latestRequest = request
        return request
    }

    /// Whether `package` should replace `held` as the trail the watch draws,
    /// matches against and keeps on disk.
    ///
    /// A package answering any earlier request is late, even for the same
    /// trail: the latest request may already hold the current revision and
    /// need no reply. The read timestamp also orders two copies of the trail
    /// already held, including arrivals after a relaunch before a request has
    /// been made — ``WatchTrailPackage/sentAt`` is when the phone read the
    /// route. The same moment is taken: it is the same read, or one no older.
    public func accepts(_ package: WatchTrailPackage, replacing held: WatchTrailPackage?) -> Bool {
        if let latestRequest,
           package.hikeID != latestRequest.hikeID || package.requestID != latestRequest.id { return false }
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
