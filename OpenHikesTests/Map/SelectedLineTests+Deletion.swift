//
//  SelectedLineTests+Deletion.swift
//  OpenHikesTests
//
//  A hike deleted here while something still reads its line: *Delete Hike*
//  on the hike's own screen, which holds the hike for the pass the pop draws,
//  with a refresh the store watch asked for before the deletion and started
//  after it. Its read took the path for a hike with no context, which read
//  the line off the detached row, and that trapped (#1687 review). See
//  ``Hike/hasLeftItsStore``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension WidgetFeedSuites.SelectedLineTests {
    @Test("a refresh asked for before a hike is deleted here reads it as gone")
    func aRefreshQueuedBeforeADeletionReadsTheHikeAsGone() async throws {
        let photos = HikePhotoImportTests.Sandbox()
        let hike = Fixture.hike(in: context)
        try context.save()
        let lines = SelectedLine()
        let read = lines.read(of: hike)
        #expect(await read.route.count == Fixture.ridgeRoute.count)

        lines.refresh()
        try HikeDeletion.delete([hike], store: photos.store)
        #expect(hike.modelContext == nil, "the deletion was saved before the refresh began")
        await lines.refreshing?.value

        #expect(read.isReplaced, "the readers are told the line has gone")
        #expect(await lines.read(of: hike).route.isEmpty)
    }

    /// The same hike asked about anew, as a screen's own reader asks after
    /// a deletion it has not heard of yet.
    @Test("a hike deleted here reads as an empty line")
    func aHikeDeletedHereReadsAsNothing() async throws {
        let photos = HikePhotoImportTests.Sandbox()
        let hike = Fixture.hike(in: context)
        try context.save()
        try HikeDeletion.delete([hike], store: photos.store)

        #expect(await SelectedLine().read(of: hike).route.isEmpty)
    }
}
