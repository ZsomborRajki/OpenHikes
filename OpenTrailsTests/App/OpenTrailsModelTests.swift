//
//  OpenTrailsModelTests.swift
//  OpenTrailsTests
//

import SwiftData
import Testing
@testable import OpenTrails

@MainActor
@Suite("OpenTrails model")
struct OpenTrailsModelTests {
    private enum PersistentStoreFailure: Error {
        case unavailable
    }

    @Test("a persistent-store failure falls back to temporary storage")
    func persistentStoreFailureFallsBack() throws {
        let temporary = try Fixture.modelContainer()
        var fallbackWasUsed = false

        let load = try OpenTrailsModel.loadContainer(
            persistent: {
                throw PersistentStoreFailure.unavailable
            },
            fallback: {
                fallbackWasUsed = true
                return temporary
            }
        )

        #expect(load.container === temporary)
        #expect(fallbackWasUsed)
        #expect(load.startupIssue != nil)
    }

    @Test("a healthy persistent store does not build a fallback")
    func persistentStoreWins() throws {
        let persistent = try Fixture.modelContainer()
        var fallbackWasUsed = false

        let load = try OpenTrailsModel.loadContainer(
            persistent: { persistent },
            fallback: {
                fallbackWasUsed = true
                return try Fixture.modelContainer()
            }
        )

        #expect(load.container === persistent)
        #expect(!fallbackWasUsed)
        #expect(load.startupIssue == nil)
    }
}
