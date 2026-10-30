//
//  BackgroundTrailTracker+SelectedLine.swift
//  OpenHikes
//
//  Following the selected hike's line, so a line replaced under the same
//  hike — *Edit Route*, heights filled in, or a line ``SelectedLine/refresh()``
//  found new in the store — reaches the widget without a change of selection.
//
//  Its own file, alongside `+RouteDistance` and the others, because
//  `BackgroundTrailTracker.swift` is at its `file_length` limit, and this piece
//  opens nothing up but the two members it alone uses (#1232).
//

import Foundation
import OpenHikesData

extension BackgroundTrailTracker {
    /// The selected hike's line as the widget was handed it, and the watch
    /// that hears it replaced.
    struct FollowedLine {
        weak var hike: Hike?
        let read: SelectedLine.Read
        let write: SelectedLine.Write
        /// The comparison a write to the line started, if any. Readable so a
        /// suite can wait on the effect rather than on a duration.
        var check: Task<Void, Never>?
    }

    /// Arms the watch on `hike`'s line, then reads the line — in that order,
    /// so a write after the read is heard.
    func followLine(of hike: Hike) -> FollowedLine {
        let write = lines.watch(hike) { [weak self] write in self?.lineDidChange(write) }
        return FollowedLine(hike: hike, read: lines.read(of: hike), write: write)
    }

    /// Publishes a line written under the selected hike as the hike selected
    /// again, which draws it on the widget and registers its region — once it
    /// has been compared, off the main actor, with the line the widget has. A
    /// new read is not always a new line: while the hikes list is up, every
    /// save of any hike tells this watch it was written (#1228), and a
    /// publication spends a widget reload.
    private func lineDidChange(_ write: SelectedLine.Write) {
        guard let followed = followedLine, write === followed.write, let hike = followed.hike,
              hike.id == trackedHikeID else { return }
        // Followed again before the comparison, so a write during it is
        // heard too; the widget's line stays the one compared against.
        let next = followLine(of: hike)
        var following = FollowedLine(hike: hike, read: followed.read, write: next.write)
        following.check = Task { [weak self] in
            guard await SelectedLine.differ(followed.read, next.read),
                  let self,
                  followedLine?.write === next.write
            else { return }
            hikeSelectionChanged(to: hike)
        }
        followedLine = following
    }
}
