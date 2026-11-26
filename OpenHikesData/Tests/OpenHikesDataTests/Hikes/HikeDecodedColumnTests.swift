//
//  HikeDecodedColumnTests.swift
//  OpenHikesDataTests
//
//  What a deleted hike answers once the save has detached it, which a screen
//  still showing it reads as the pop takes it away. Its plain columns answer
//  whatever happened before; a column SwiftData decodes answers only if it
//  was read since the hike's last save, and traps otherwise. These pin that,
//  and hold ``Hike/resolveDecodedColumns()`` to every decoded column the
//  schema has. See that method for the crash it answers.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("A deleted hike's decoded columns")
struct HikeDecodedColumnTests {
    /// The decoded columns ``Hike/resolveDecodedColumns()`` leaves out: the
    /// lines, which are external storage and read off the main actor.
    private static let lines: Set<String> = ["route", "rawRoute", "originalRoute"]
    /// The ones it reads.
    private static let resolved: Set<String> = ["photos", "surfaceMetersByCategory", "difficultyMetersByGrade"]

    /// The types SwiftData stores as they are, which a detached row answers
    /// without having been read.
    private static let plainTypes: [Any.Type] = [
        String.self, String?.self, Bool.self, Double.self, Double?.self, Int.self, Int64.self,
        Date.self, UUID.self, Data?.self,
    ]

    @Test("every decoded column is resolved before a deletion, or is a line")
    func everyDecodedColumnIsResolvedOrALine() throws {
        let hike = try #require(Schema([Hike.self]).entities.first { $0.name == "Hike" })
        let decoded = Set(
            hike.attributes
                .filter { attribute in !Self.plainTypes.contains { $0 == attribute.valueType } }
                .map(\.name)
        )

        #expect(
            decoded == Self.lines.union(Self.resolved),
            "a new decoded column traps when a screen reads it off a deleted hike: resolve it before the delete"
        )
    }

    /// The deletion path's order: whatever the hike held is saved first,
    /// then its columns are resolved, and then it is deleted and saved.
    @Test("a hike saved with changes of its own still answers its decoded columns once deleted")
    func resolvedColumnsSurviveTheDeletion() throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let hike = Hike(
            title: "Ridge",
            distanceMeters: 1200,
            surfaceMetersByCategory: ["paved": 400],
            difficultyMetersByGrade: ["T1": 1200],
            photos: [HikePhoto(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 19))]
        )
        context.insert(hike)
        try context.save()
        _ = hike.photos
        hike.surfaceMetersByCategory = ["paved": 400, "gravel": 800]
        try context.save()

        hike.resolveDecodedColumns()
        context.delete(hike)
        try context.save()

        #expect(hike.modelContext == nil, "the save detached it")
        #expect(hike.photos.count == 1)
        #expect(hike.surfaceMetersByCategory == ["paved": 400, "gravel": 800])
        #expect(hike.difficultyMetersByGrade == ["T1": 1200])
    }

    private static func container() throws -> ModelContainer {
        let schema = Schema(OpenHikesSchema.models)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
}
