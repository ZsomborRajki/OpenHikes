//
//  SheetRouteTests.swift
//  OpenTrailsTests
//

import Testing
@testable import OpenTrails

@MainActor
@Suite("Sheet route")
struct SheetRouteTests {
    @Test("reopening recording pops anything pushed above it")
    func reopensExistingRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.recording, .hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.recording])
    }

    @Test("opening recording appends it when no session route exists")
    func appendsRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.hike(hike), .recording])
    }
}
