//
//  RouteEditChecksTests+OtherDevice.swift
//  OpenHikesTests
//
//  *Looks Good* while an edit from the hiker's other device lands. The
//  screen is keyed on the line and the edit record and reloads when either
//  moves, but the look can be tapped before it has, or the reload can land
//  between the tap and the look: a look taken from the hike as it stands by
//  then would mark checks nobody on this screen has seen. So it is refused,
//  as Save is, and the checks stay owed. Held while the store is still
//  bringing the other device's line in: `RouteTrimDestinationTests`.
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

        #expect(await !look(session, at: hike, in: context))
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

        #expect(await !look(session, at: hike, in: context))
        #expect(session.refusal == .lineChanged)
        let edit = try #require(hike.routeEdit)
        #expect(edit.isOwedALook)
        #expect(edit.uncheckedNotOnFoot != nil, "the drive off the end is still asked about")
        #expect(edit.uncheckedCount == 1, "and so is the stretch")
    }

    /// The tap is on what the screen showed. A reload already queued when
    /// the hiker tapped lands before the look runs, and the checks it brings
    /// are not the ones looked at.
    @Test("Looks Good tapped before the other device's record reloads is refused once it has")
    func lookOvertakenByAReloadIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        let tapped = session.sourcesRevision
        hike.routeEdit = RouteEdit(assembly: Self.assembly, notOnFoot: RouteEdit.NotOnFoot(Self.carriedEnds))
        try context.save()

        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))

        #expect(await !look(session, at: hike, in: context, tappedOn: tapped))
        #expect(session.refusal == .lineChanged)
        #expect(hike.routeEdit?.uncheckedNotOnFoot != nil, "the drive off the end is still asked about")
        #expect(session.isOwedALook, "and the screen, now showing it, still asks")
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

        #expect(await look(session, at: hike, in: context))
        #expect(hike.routeEdit?.isOwedALook == false)
    }

    /// A record keeps a figure that is not a number rather than refusing to
    /// be written — see ``RouteEdit/encoder()`` — and such a record is never
    /// equal to itself, so the look is held to its bytes.
    @Test("Looks Good takes a record holding a figure that is not a number")
    func lookAtARecordWithANonFiniteFigure() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        hike.originalRoute = Self.saved
        var edit = try #require(hike.routeEdit)
        edit.original = RouteEdit.Original(distanceMeters: .nan, date: hike.date, recordedWalk: nil, notOnFoot: nil)
        hike.routeEdit = edit
        try context.save()
        let session = await visit(hike, in: context)
        #expect(session.isOwedALook, "precondition: the record opens, and asks")

        #expect(await look(session, at: hike, in: context))
        #expect(session.refusal == nil)
        #expect(hike.routeEdit?.isOwedALook == false)
        #expect(hike.routeEdit?.original?.distanceMeters.isNaN == true, "and the figure is kept as it was")
    }
}
