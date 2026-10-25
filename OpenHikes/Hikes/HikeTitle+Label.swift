// Generated hike names are app words; bounds remain in OpenHikesData.

import Foundation
import OpenHikesData

nonisolated extension HikeTitle {
    /// The same, for one track of a file that holds several: an unnamed
    /// track is the file's name with its place in the file, because every
    /// track of it falling back to the bare file name is a list of identical
    /// rows nobody can tell apart.
    static func imported(trackName: String?, fileURL: URL, trackNumber: Int) -> String {
        bounded(trackName)
            ?? bounded(String(localized: "\(fileURL.deletingPathExtension().lastPathComponent), Track \(trackNumber)"))
            ?? ""
    }

    /// The name a trail drawn on the map gets: what the hiker typed, otherwise
    /// the day they drew it.
    ///
    /// Here rather than inside ``TrailDraftSave`` for the reason
    /// ``imported(trackName:fileURL:)`` is here rather than inside
    /// `HikeImport`: which source wins is a decision, a suite should be able
    /// to drive it without a `ModelContainer`, and this file is where a new
    /// way of naming a hike has to arrive — a title is bounded where it is
    /// entered, and the maker's field is a new place to enter one.
    ///
    /// The date fallback rather than an empty string, and for the reason the
    /// watch's is: an empty name leaves two unnamed trails indistinguishable
    /// in a list, and a drawn trail has no file and no track name to fall back
    /// on the way an import does.
    static func drawn(name: String?, madeOn date: Date) -> String {
        bounded(name) ?? bounded(
            String(localized: "Trail, \(date.formatted(date: .abbreviated, time: .shortened))")
        ) ?? ""
    }

    /// The name a walk recorded on the watch gets: the trail it was walked
    /// along, otherwise the day it was walked on.
    ///
    /// Here rather than inside `WatchWalkImport` for the reason
    /// ``imported(trackName:fileURL:)`` is here rather than inside
    /// `HikeImport`: which source wins is a decision, a suite should be able
    /// to drive it without a `ModelContainer`, and a name arriving from
    /// another device is the sender's exactly as a GPX `<name>` is.
    ///
    /// The date fallback rather than an empty string, because this name is
    /// also the only thing distinguishing two free recordings in a list —
    /// where an import at least has the file it came from to fall back to.
    static func watchRecording(trailName: String?, recordedAt: Date) -> String {
        bounded(trailName) ?? bounded(
            String(localized: "Watch Hike, \(recordedAt.formatted(date: .abbreviated, time: .shortened))")
        ) ?? ""
    }
}
