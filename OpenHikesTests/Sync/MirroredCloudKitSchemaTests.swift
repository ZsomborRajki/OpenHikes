//
//  MirroredCloudKitSchemaTests.swift
//  OpenHikesTests
//
//  The checked-in record of the mirrored schema, held against the model.
//
//  ``MirroredCloudKitSchema`` exists because whether a record type has reached
//  the production CloudKit schema is a fact about a browser session, which no
//  test can reach. What a test *can* do is make sure nobody adds to the
//  mirrored schema without seeing that file: the parity check below fails on
//  any entity, attribute or relationship the model and the record disagree
//  about, and its message says what the deploy costs if it is missed.
//
//  The rest of the suite pins the three constraints CloudKit mirroring
//  imposes on the model itself. All three are stated in the header of
//  `ModelConfiguration+OpenHikes.swift` and none of them was checked: they
//  fail at store-open time, on a device, with the app refusing to launch —
//  which in the mandatory-attribute case means refusing to launch for exactly
//  the people who already have hikes saved.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Mirrored CloudKit schema")
struct MirroredCloudKitSchemaTests {
    private var mirrored: Schema {
        Schema(OpenHikesSchemaV3.hikeModels, version: OpenHikesSchemaV3.versionIdentifier)
    }

    private var sidecar: Schema {
        Schema(OpenHikesSchemaV3.localStateModels, version: OpenHikesSchemaV3.versionIdentifier)
    }

    private func described(_ entity: Schema.Entity) -> MirroredCloudKitSchema.RecordType {
        MirroredCloudKitSchema.RecordType(
            entity: entity.name,
            attributes: entity.attributes.map(\.name).sorted(),
            relationships: entity.relationships.map(\.name).sorted()
        )
    }

    /// The record and the model, field for field.
    ///
    /// This is the whole point of the file it checks. A column added to
    /// ``Hike``, or a third mirrored entity, lands here first — and the
    /// failure is what puts the production deploy in front of whoever added
    /// it, which is the step that has no other reminder anywhere.
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

            Update the record, and note that whatever it gained has to be \
            deployed to the production CloudKit schema in the Console before a \
            build carrying it ships. Production does not create schema on \
            demand, and rows written before the deploy never export.
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

    /// A deployment note has to name a record type that still exists and carry
    /// a date that is one.
    ///
    /// An entry for a type no longer in the schema is a stale claim about the
    /// container, which is worse than no claim: the append-only rule means a
    /// record type never actually goes away in production, so the note would
    /// go on looking like coverage of something this build no longer has.
    ///
    /// Read through a `Date.ParseStrategy` rather than a `DateFormatter` — a
    /// value type for a fixed wire-shaped date, the way ``TileRetryAdvice``
    /// reads an IMF-fixdate — and matched whole, so `2026-09-08 or so` is
    /// refused rather than half-read into a day.
    @Test
    func deploymentNotesAreWellFormed() {
        let known = Set(MirroredCloudKitSchema.recordTypes.map(\.entity))

        for (recordType, day) in MirroredCloudKitSchema.productionDeployments {
            #expect(known.contains(recordType), "\(recordType) is not in the mirrored schema")
            #expect(
                day.wholeMatch(of: Self.isoDay) != nil,
                "\(recordType) has an unreadable date: \(day)"
            )
        }

        let pending = MirroredCloudKitSchema.pendingProductionDeployment
        #expect(pending.allSatisfy(known.contains))
    }

    /// The date rule above, exercised directly.
    ///
    /// ``MirroredCloudKitSchema/productionDeployments`` is empty until the
    /// first deploy, so the loop that applies this rule iterates nothing and
    /// would go on passing however the rule were broken. This is what makes it
    /// a check rather than a shape: the day a note is written down, the reader
    /// it will be read by has already been tested.
    @Test
    func aDeploymentDateIsADay() {
        let day = "2026-09-08".wholeMatch(of: Self.isoDay)?.output
        #expect(day != nil)

        // `.twoDigits` is a padding rule for writing, not a width the reader
        // insists on. An unpadded note is read, and reads as the same day —
        // measured rather than assumed, because the first version of this
        // test asserted the opposite and went red.
        #expect("2026-9-8".wholeMatch(of: Self.isoDay)?.output == day)

        // What it does refuse: a different order, and anything the note says
        // besides the day.
        #expect("08-09-2026".wholeMatch(of: Self.isoDay) == nil)
        #expect("2026-09".wholeMatch(of: Self.isoDay) == nil)
        #expect("2026-09-08 or so".wholeMatch(of: Self.isoDay) == nil)
        #expect("soon".wholeMatch(of: Self.isoDay) == nil)
    }

    /// `yyyy-MM-dd`, POSIX and UTC: a day written down, not a rendering of one
    /// for a person to read.
    private static let isoDay = Date.ParseStrategy(
        format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .gmt,
        isLenient: false
    )

    /// The sidecar stays out of the mirrored store, and the mirrored models
    /// stay out of the sidecar.
    ///
    /// The split is what keeps *this* device's tile inventory from being
    /// merged last-writer-wins with another device's — see ``HikeLocalState``.
    /// A model listed in both, or moved between them, would be that failure
    /// with nothing to notice it.
    @Test
    func theSidecarIsNotMirrored() {
        let mirroredNames = Set(mirrored.entities.map(\.name))
        let sidecarNames = Set(sidecar.entities.map(\.name))

        #expect(sidecarNames == ["HikeLocalState"])
        #expect(mirroredNames.isDisjoint(with: sidecarNames))
        #expect(!mirroredNames.contains("HikeLocalState"))
    }

    /// Every mandatory attribute carries a default.
    ///
    /// Mirroring refuses to open a store whose non-optional attributes cannot
    /// be backfilled, and says so by failing to launch. The inline defaults on
    /// ``Hike`` and ``HikeWalk`` are there for this, and each carries a comment
    /// saying so; this is what makes the next column keep the promise.
    @Test
    func mandatoryAttributesCanBeBackfilled() {
        for entity in mirrored.entities {
            for attribute in entity.attributes where !attribute.isOptional {
                let name = "\(entity.name).\(attribute.name)"
                #expect(
                    attribute.defaultValue != nil,
                    "\(name) is mandatory with no default, so a store carrying earlier rows cannot be opened."
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
