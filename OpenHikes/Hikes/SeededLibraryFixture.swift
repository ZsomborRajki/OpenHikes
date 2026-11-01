//
//  SeededLibraryFixture.swift
//  OpenHikes
//
//  A library with several hikes in it, behind `--ui-test-seed-hikes=<count>`.
//
//  Everything about a *list* — what order it comes out in, what a drag does to
//  it, which row is pinned — needs more than one row, and the GPX fixture makes
//  exactly one. Importing it repeatedly would spend a scenario's whole budget
//  parsing the same file for hikes whose contents no list test reads.
//
//  So these are deliberately thin: a title, a date, and a short route, written
//  through the real store. What a test reads afterwards is the shipping query
//  and the shipping row; only the walking is invented. Mirrors
//  ``SeededWalkFixture``, and like it is compiled only into `DEBUG`.
//
//  The dates descend by a day from the first, which is what makes the expected
//  order knowable from the titles alone: *Seeded Trail 1* is the newest, so it
//  is the row a date-ordered list draws first.
//
//  The map needs the opposite: hikes that differ in where they go. All of the
//  bare hikes walk one route, which the map draws as one line however many of
//  them there are, so `--ui-test-seed-nearby-trails` puts three different
//  trails in the library instead, each from its own GPX and in its own colour,
//  starting within a kilometre of one another at the Königssee.
//

import Foundation
import OpenHikesData
import SwiftData

#if DEBUG
nonisolated enum SeededLibraryFixture {
    /// The bundled GPX every other fixture here walks, parsed once and given
    /// to all of them.
    ///
    /// Hand-written coordinates would be the only ones in the app target —
    /// geometry in this project comes from a file — and a list row reads a
    /// distance rather than a shape, so sharing one route across the seeded
    /// hikes costs a test nothing and keeps the convention.
    private static let sharedRoute = "ThumseeLoopFast"

    /// Midnight `daysAgo` days back.
    ///
    /// Built through `Calendar` rather than from a seconds offset, for the
    /// reason ``SeededWalkFixture/morning(daysAgo:hour:minute:)`` gives: a
    /// fixture dated by arithmetic drifts against the clock the row formats it
    /// with. A day apart is far enough that nothing here depends on how that
    /// formatting rounds.
    private static func date(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: midnight) ?? midnight
    }

    @MainActor
    static func seed(count: Int, in context: ModelContext) {
        guard count > 0,
              let url = Bundle.main.url(forResource: sharedRoute, withExtension: "gpx"),
              let track = try? GPXImport.load(from: url) else { return }
        for index in 0..<count {
            let hike = Hike(
                title: "Seeded Trail \(index + 1)",
                distanceMeters: track.distanceMeters,
                route: track.route
            )
            // Descending, so the numbering reads down the screen: the list is
            // newest-first, and a test that has to work out which row *should*
            // be on top is a test that can agree with a bug.
            hike.date = Self.date(daysAgo: index)
            context.insert(hike)
        }
        try? context.save()
    }

    /// The trails ``seedNearbyTrails(in:)`` adds, newest first: the bundled
    /// GPX each walks, and its title. The same files the *Community* tab's
    /// showcase draws (`SeededCommunityShowcase`).
    static let nearbyTrails: [(fixture: String, title: String)] = [
        ("KoenigsseeMalerwinkel", "Malerwinkel Loop"),
        ("KoenigsseeRinnkendlsteig", "Rinnkendlsteig"),
        ("KoenigsseeGotzenalm", "Gotzenalm"),
    ]

    /// Adds the ``nearbyTrails``, dated a day apart like the bare hikes and
    /// coloured a third of the palette's wheel apart, so no two of the lines
    /// can be taken for one another.
    @MainActor
    static func seedNearbyTrails(in context: ModelContext) {
        for (index, trail) in nearbyTrails.enumerated() {
            guard let url = Bundle.main.url(forResource: trail.fixture, withExtension: "gpx"),
                  let track = try? GPXImport.load(from: url) else { continue }
            context.insert(Hike(
                title: trail.title,
                distanceMeters: track.distanceMeters,
                date: Self.date(daysAgo: index),
                tintHex: RouteTint.color(hue: Double(index) / Double(nearbyTrails.count)).hexRGBA,
                route: track.route
            ))
        }
        try? context.save()
    }
}
#endif
