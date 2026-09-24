//
//  MirroredCloudKitSchemaTests.swift
//  OpenHikesTests
//
//  Current mirrored fields and CloudKit model constraints.
//  See "Schema and migration policy" in the repository instructions.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Mirrored CloudKit schema")
struct MirroredCloudKitSchemaTests {
    private var mirrored: Schema {
        Schema(OpenHikesSchema.hikeModels, version: OpenHikesSchema.versionIdentifier)
    }

    private var sidecar: Schema {
        Schema(OpenHikesSchema.localStateModels, version: OpenHikesSchema.versionIdentifier)
    }

    private func described(_ entity: Schema.Entity) -> MirroredCloudKitSchema.RecordType {
        MirroredCloudKitSchema.RecordType(
            entity: entity.name,
            attributes: entity.attributes.map(\.name).sorted(),
            relationships: entity.relationships.map(\.name).sorted()
        )
    }

    @Test
    func recordMatchesTheModel() {
        let live = mirrored.entities.map(described).sorted { $0.entity < $1.entity }
        let recorded = MirroredCloudKitSchema.recordTypes.sorted { $0.entity < $1.entity }

        #expect(
            live == recorded,
            """
            The mirrored schema and MirroredCloudKitSchema.recordTypes disagree.

            Model:  \(live)
            Record: \(recorded)

            Update the current field record and follow "Schema and migration \
            policy" in .github/copilot-instructions.md for the CloudKit deployment.
            """
        )
    }

    /// The record's own field lists have to be sorted and free of duplicates,
    /// since the comparison above is order-sensitive and a duplicate would
    /// otherwise read as a field the model is missing.
    @Test
    func recordIsSortedAndUnique() {
        for type in MirroredCloudKitSchema.recordTypes {
            #expect(type.attributes == type.attributes.sorted(), "\(type.entity) attributes")
            #expect(Set(type.attributes).count == type.attributes.count, "\(type.entity) attributes")
            #expect(type.relationships == type.relationships.sorted(), "\(type.entity) relationships")
        }
    }

    /// The sidecar stays out of the mirrored store, and the mirrored models
    /// stay out of the sidecar.
    ///
    /// The split is what keeps *this* device's tile inventory from being
    /// merged last-writer-wins with another device's — see ``HikeLocalState``.
    /// A model listed in both, or moved between them, would be that failure
    /// with nothing to notice it.
    ///
    /// ``TrailDraftRecord`` is here for a related reason of its own: a
    /// half-drawn trail is one device's unfinished work, and mirroring it
    /// would put a line nobody has finished into the hiker's other devices and
    /// then resolve two people drawing at once last-writer-wins. The list is
    /// spelled out rather than counted so that *moving* a model into the
    /// mirrored store fails here rather than on somebody's second phone.
    @Test
    func theSidecarIsNotMirrored() {
        let mirroredNames = Set(mirrored.entities.map(\.name))
        let sidecarNames = Set(sidecar.entities.map(\.name))

        #expect(sidecarNames == ["HikeLocalState", "TrailDraftRecord"])
        #expect(mirroredNames.isDisjoint(with: sidecarNames))
    }

    /// CloudKit requires defaults even for a fresh mirrored store.
    @Test
    func mandatoryAttributesHaveDefaults() {
        for entity in mirrored.entities {
            for attribute in entity.attributes where !attribute.isOptional {
                let name = "\(entity.name).\(attribute.name)"
                #expect(
                    attribute.defaultValue != nil,
                    "\(name) is mandatory with no default, which CloudKit mirroring forbids."
                )
            }
        }
    }

    /// Every relationship is optional, which CloudKit mirroring requires.
    @Test
    func relationshipsAreOptional() {
        for entity in mirrored.entities {
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name)")
            }
        }
    }

    /// No uniqueness constraints, which CloudKit mirroring forbids outright.
    ///
    /// ``Hike`` documents choosing `#Index` over `#Unique` on its own merits
    /// and then records that mirroring settles it; this is the settlement.
    @Test
    func noUniquenessConstraints() {
        for entity in mirrored.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name)")
        }
    }
}
