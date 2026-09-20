//
//  SeededWalkFixture.swift
//  OpenHikes
//
//  A walk along a hike nobody walked, behind `--ui-test-seed-walks=<name>`.
//
//  The History segment and the Walk Summary are about a *finished* walk, and
//  finishing one in the Simulator is a minute of simulated fixes per
//  scenario — too slow for a check that a row reads as one element, or that
//  the summary leads with a percentage. This writes the row directly, through
//  the real store, so what a test reads afterwards is the shipping query, the
//  shipping cascade and the shipping formatting; only the walk is invented.
//
//  Mirrors `SeededPhotoFixture`, and like it is compiled only into `DEBUG`.
//

import Foundation
import SwiftData

#if DEBUG
nonisolated enum SeededWalkFixture {
    /// One walk a launch may ask for, by name.
    ///
    /// Two of them, and the pair is the point. ``halfLoop`` is a walk that
    /// stopped partway, which is what the row's percentage and the summary's
    /// "left to walk" are *for*; ``fullLoop`` is one that finished, which is
    /// the other end of the same formatting and the only one that reads
    /// 100%. A screen that has only ever been seen at one of the two has had
    /// half of itself written blind.
    private struct Walk {
        let name: String
        /// How much of the route was covered, 0...1.
        let fraction: Double
        /// Time spent moving, which is what the summary reports.
        let activeSeconds: TimeInterval
        /// How many days before today the walk happened.
        let daysAgo: Int
        /// The hour of the morning it set off at.
        let hour: Int
        let minute: Int
        /// How it stopped, which is the word the row prints beside the
        /// percentage — see ``WalkRow/outcome(_:)``. Part of the fixture
        /// rather than assumed, because the two walks below stopped for
        /// different reasons and a 100% walk labelled *Ended* is a row the
        /// app itself would never write.
        let endReason: TrailWalkEndReason
    }

    /// Half the route, ended by the hiker partway along.
    private static let halfLoop = Walk(
        name: "HalfLoop",
        fraction: 0.5,
        activeSeconds: 45 * 60,
        daysAgo: 3,
        hour: 10,
        minute: 15,
        endReason: .ended
    )

    /// The whole route, finished. The hours are a real pace for the ten
    /// kilometres and nine hundred metres of climb the screenshot fixture
    /// carries, so the summary's moving time reads as a day out rather than
    /// as a number nobody checked.
    private static let fullLoop = Walk(
        name: "FullLoop",
        fraction: 1.0,
        activeSeconds: 3 * 3600 + 50 * 60,
        // More recent than ``halfLoop``, so a launch that asks for both gets
        // the finished walk at the top of the list, where History puts the
        // newest one.
        daysAgo: 1,
        hour: 8,
        minute: 40,
        // What the app writes for a walk that reached the route's end, and the
        // only reason that reads *Completed*. A frame captioned "a trail
        // walked end to end" cannot be a row saying the hiker stopped.
        endReason: .reachedEnd
    )

    private static let all = [halfLoop, fullLoop]

    /// Attaches every walk `names` asks for, as a comma-separated list.
    ///
    /// A list rather than one name because a history with a single row in it
    /// is not a history: the screen's job is to put walks beside each other,
    /// and the finished one only means something next to the one that stopped
    /// halfway. Unknown names are skipped rather than refused — the launch
    /// argument is a developer's, and a typo should cost a missing row rather
    /// than a crash on a screen that has nothing to do with walks.
    @MainActor
    static func attach(named names: String, to hike: Hike, in context: ModelContext) {
        for name in names.split(separator: ",") {
            attach(one: String(name), to: hike, in: context)
        }
    }

    /// A wall-clock morning `daysAgo` days back.
    ///
    /// A time of day rather than an offset from launch, which is what this
    /// was. `Date(timeIntervalSinceNow: -20 * 3600)` puts the walk twenty
    /// hours before whenever the app happened to start, so an afternoon run
    /// produced a summary that set off at 20:14 and finished after midnight —
    /// true to the fixture and wrong about hiking.
    private static func morning(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: midnight) ?? midnight
        return calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: day
        ) ?? day
    }

    @MainActor
    private static func attach(one name: String, to hike: Hike, in context: ModelContext) {
        guard let fixture = all.first(where: { $0.name == name }),
              hike.isAttached else { return }
        let routeDistance = hike.distanceMeters
        let covered = routeDistance * fixture.fraction
        let startedAt = Self.morning(
            daysAgo: fixture.daysAgo,
            hour: fixture.hour,
            minute: fixture.minute
        )
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(fixture.activeSeconds),
            activeSeconds: fixture.activeSeconds,
            coveredIntervals: [0, covered],
            furthestDistanceMeters: covered,
            routeDistanceMeters: routeDistance,
            endReason: fixture.endReason
        )
        context.insert(walk)
        walk.hike = hike
        try? context.save()
    }
}
#endif
