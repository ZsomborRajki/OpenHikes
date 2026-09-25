//
//  HikeEntity+Reports.swift
//  OpenHikes
//
//  Building a ``HikeEntity`` from the app's own report type.
//
//  The entity itself lives in OpenHikesShared, because the widget's
//  configuration intent takes one and that intent is compiled into
//  OpenWidgetExtension — see that file's header. ``FinishedHikeReport`` does
//  not and should not: it is the app's answer about its own store, and moving
//  it would take `HikeIntentCoordinator` with it.
//
//  So the bridge is here, in the target that has both. One initializer rather
//  than a conformance, which is all the seam needs.
//

import Foundation
import OpenHikesShared

/// `nonisolated` spelled on the extension rather than inherited, because an
/// unannotated extension's `static` members are inferred differently by the
/// two compilers this project is built with — it compiles on Xcode 27 and
/// fails on CodeQL's Xcode 26.6 with "main actor-isolated static property
/// cannot be accessed from outside of the actor". It is also correct on its
/// own terms: both members below are pure value work, and neither has any
/// business on the main actor.
nonisolated extension HikeEntity {
    init(_ report: FinishedHikeReport) {
        self.init(
            id: report.id,
            name: report.title,
            date: report.date,
            distance: report.distance,
            duration: report.duration
        )
    }

    /// The same report as a catalogue row — what the app publishes to the App
    /// Group so a picker in another process has something to offer.
    ///
    /// Beside the initializer above because the two must agree about what a
    /// hike's *name* is: ``FinishedHikeReport/title`` is already the resolved
    /// display name, and a catalogue built from anything else would offer
    /// hikes under names the hiker has never seen — which is the whole of what
    /// `HikeSearch`'s header argues about `customName`.
    static func summary(of report: FinishedHikeReport) -> SharedHikeSummary {
        SharedHikeSummary(
            id: report.id,
            name: report.title,
            date: report.date,
            distanceMeters: report.distance.converted(to: .meters).value,
            durationSeconds: report.duration
        )
    }
}
