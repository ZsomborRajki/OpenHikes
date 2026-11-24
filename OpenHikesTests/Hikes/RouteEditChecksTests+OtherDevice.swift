//
//  RouteEditChecksTests+OtherDevice.swift
//  OpenHikesTests
//
//  *Looks Good* while an edit from the hiker's other device lands. The
//  screen is keyed on the line and the edit record and reloads when either
//  moves, but the look can be tapped before it has: a look taken from the
//  hike as it stands by then would mark checks nobody on this screen has
//  seen. So it is refused, as Save is, and the checks stay owed.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension RouteEditChecksTests {
    @Test("Looks Good on a line replaced from the other device is refused, and the hike still asks")
    func lookAtAReplacedLineIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)

        // iCloud brings the other device's line before this screen reloads.
        hike.replaceRoute(with: Self.saved.map { point in
            RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude + Line.traceOffset,
                timestamp: point.timestamp
            )
        })
        try context.save()

        #expect(await !session.confirmChecks(in: destination(for: hike, in: context)))
        #expect(session.refusal == .lineChanged)
        #expect(hike.routeEdit?.isOwedALook == true)
        #expect(session.isOwedALook)
    }

    /// The same line, and a record that now also asks about a drive off the
    /// end: a look the hiker gave the record they saw is not a look at this.
    @Test("Looks Good on a review record changed from the other device is refused")
    func lookAtAChangedRecordIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)

        hike.routeEdit = RouteEdit(assembly: Self.assembly, notOnFoot: RouteEdit.NotOnFoot(Self.carriedEnds))
        try context.save()

        #expect(await !session.confirmChecks(in: destination(for: hike, in: context)))
        #expect(session.refusal == .lineChanged)
        let edit = try #require(hike.routeEdit)
        #expect(edit.isOwedALook)
        #expect(edit.uncheckedNotOnFoot != nil, "the drive off the end is still asked about")
        #expect(edit.uncheckedCount == 1, "and so is the stretch")
    }

    /// Once the screen has reloaded on the new record, what it shows is what
    /// is looked at.
    @Test("after the screen reloads on the other device's record, Looks Good takes it")
    func lookAfterReloadIsTaken() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        hike.routeEdit = RouteEdit(assembly: Self.assembly, notOnFoot: RouteEdit.NotOnFoot(Self.carriedEnds))
        try context.save()

        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))

        #expect(await session.confirmChecks(in: destination(for: hike, in: context)))
        #expect(hike.routeEdit?.isOwedALook == false)
    }
}
