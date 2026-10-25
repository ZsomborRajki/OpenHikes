//
//  HikeImportReport.swift
//  OpenHikes
//
//  What the map screen has left to say about the files the hiker imported:
//  why one did not become a hike, and that one did without every place it
//  marked.
//
//  The second is news only for a file that asked nothing first. A file of
//  several tracks says what the cap will cut in its confirmation's footer,
//  before anything lands (``GPXTrackChoiceSheet/leftOutNote(offTrack:pastPlaceLimit:)``);
//  a file of one track imports straight away, so the import's own outcome is
//  the only place left to say it (#1076). It is said after the hike is kept
//  rather than instead of keeping it: the line and the first places are fine,
//  and the cap is policy, not a fault in the file — see
//  ``GPXImport/maximumPlaces``.
//
//  One value rather than two, so the notice can wait for a failure alert
//  raised by the same pick of several files: SwiftUI presents one alert at a
//  time, and an alert raised while another is up is lost.
//

import Foundation

/// The map screen's import alerts, as one value — see ``MapScreenAlerts``.
struct HikeImportReport: Equatable {
    /// A file that couldn't become a kept hike.
    var failure: HikeImportFailure?
    /// Files that became hikes without all of their places.
    var placeNotice: HikeImportPlaceNotice?
}

/// That an import kept its hikes but left out places past
/// ``GPXImport/maximumPlaces``, and nothing had said so before it did.
struct HikeImportPlaceNotice: Equatable {
    /// One file the cap cut places from.
    struct File: Equatable {
        let fileName: String
        let placesPastLimit: Int
    }

    /// One for a lone file; one for each such file of several picked.
    let files: [File]

    /// What the alert says under its title: the sentence alone for one
    /// file, and a line per file naming it for several, the shape the
    /// failure alert lists several files in (``HikeImportFailure/several(_:)``).
    var message: String {
        if files.count == 1, let only = files.first {
            return Self.sentence(only.placesPastLimit)
        }
        return files.map { "\($0.fileName): \(Self.sentence($0.placesPastLimit))" }.joined(separator: "\n")
    }

    /// The confirmation footer's words for the same cut, said of a track
    /// already imported. A plural variation in the catalog, so a translator
    /// can move the count.
    static func sentence(_ placesPastLimit: Int) -> String {
        String(
            localized: """
                \(placesPastLimit) more places lie on this track but weren’t imported, \
                because one file can bring only so many.
                """
        )
    }
}
