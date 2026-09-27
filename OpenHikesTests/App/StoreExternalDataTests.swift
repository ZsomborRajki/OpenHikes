//
//  StoreExternalDataTests.swift
//  OpenHikesTests
//
//  A real Core Data external binary file survives the store's move. A route's
//  point count does not guarantee that SwiftData puts its encoded value in an
//  external file, so this fixture uses a binary attribute and verifies the
//  file exists before testing the move. It never opens a CloudKit store.
//

import CoreData
import Foundation
@testable import OpenHikes
import Testing

@Suite("Store external data")
struct StoreExternalDataTests {
    @Test("an external binary payload reopens intact after the store moves")
    func externalPayloadSurvivesTheMove() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "store-external-data-\(UUID())")
        defer { try? fileManager.removeItem(at: root) }
        let legacy = root.appending(path: "Group/Library/Application Support", directoryHint: .isDirectory)
        let directory = root.appending(path: "App/Stores", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let payload = Data((0..<2_097_152).map { UInt8(truncatingIfNeeded: $0) })

        try Self.withStore(at: StoreLocation.storeURL(StoreLocation.hikes, in: legacy)) { context in
            let object = NSEntityDescription.insertNewObject(forEntityName: "Payload", into: context)
            object.setValue(payload, forKey: "bytes")
            try context.save()
        }
        let externalPath = ".Hikes_SUPPORT/_EXTERNAL_DATA"
        let externalFiles = try fileManager.contentsOfDirectory(atPath: legacy.appending(path: externalPath).path)
        try #require(!externalFiles.isEmpty, "the fixture must exercise a real external file")

        try StoreLocation.prepare(directory: directory, legacyDirectory: legacy)

        #expect(!fileManager.fileExists(atPath: legacy.appending(path: externalPath).path))
        #expect(
            try fileManager.contentsOfDirectory(atPath: directory.appending(path: externalPath).path).sorted()
                == externalFiles.sorted()
        )
        let reopened = try Self.withStore(at: StoreLocation.storeURL(StoreLocation.hikes, in: directory)) { context in
            let object = try #require(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Payload")).first)
            return try #require(object.value(forKey: "bytes") as? Data)
        }
        #expect(reopened == payload)
    }

    /// Core Data owns the same SQLite side files SwiftData uses. Closing the
    /// store explicitly also ensures the move has no live connection behind it.
    private static func withStore<Value>(
        at url: URL,
        body: (NSManagedObjectContext) throws -> Value
    ) throws -> Value {
        let attribute = NSAttributeDescription()
        attribute.name = "bytes"
        attribute.attributeType = .binaryDataAttributeType
        attribute.allowsExternalBinaryDataStorage = true
        let entity = NSEntityDescription()
        entity.name = "Payload"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [attribute]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        defer {
            context.reset()
            try? coordinator.remove(store)
        }
        return try body(context)
    }
}
