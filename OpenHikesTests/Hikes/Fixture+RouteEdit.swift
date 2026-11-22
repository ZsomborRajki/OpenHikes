//
//  Fixture+RouteEdit.swift
//  OpenHikesTests
//
//  A hike's line replaced through *Edit Route*'s own save: where the suites
//  about what follows a route edit — the line a screen shows, the library's
//  totals, a saved map's claim — start from.
//

@testable import OpenHikes
import OpenHikesData
import SwiftData

extension Fixture {
    /// Writes `line` over `hike`'s through ``RouteEditSave``, as the whole
    /// line redrawn in *Edit Route* is saved, and says whether it was.
    static func redraw(_ hike: Hike, as line: [RouteCoordinate], in context: ModelContext) -> Bool {
        guard let edited = EditedLine(
            whole: line,
            distances: RouteTrim.distances(along: line),
            cuts: EditedLine.Cuts(range: nil),
            replacing: hike.route
        ) else { return false }
        return RouteEditSave.write(edited, to: hike, replacing: hike.route, in: context).isSaved
    }
}
