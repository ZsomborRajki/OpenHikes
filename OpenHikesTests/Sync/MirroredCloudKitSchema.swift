//
//  MirroredCloudKitSchema.swift
//  OpenHikesTests
//
//  What the mirrored store asks the CloudKit container to hold, and whether
//  that has reached the *production* schema yet.
//
//  This file exists because the answer to the second question lives outside
//  the repository and outside CI. SwiftData creates the **development** schema
//  from the model on the first signed run, and production does not create
//  schema on demand: a record type or a field reaches production only when
//  somebody presses Deploy Schema Changes in the CloudKit Console for
//  ``CloudSyncCoordinator/containerIdentifier``. A build that ships carrying a
//  type production has not got does not crash and does not complain — the row
//  is written locally, the export is rejected, and the walker looks at an
//  empty list on their second device. Rows written before the deploy do not
//  retroactively export either, and the mirrored schema is append-only once
//  shipped, so it is not a mistake that can be undone by deploying again.
//
//  Nothing here can talk to CloudKit, and this deliberately does not try. What
//  it does is make the omission *loud in the one place it can be*: the two
//  lists below are the checked-in record of what has to exist in production
//  and of what has been promoted there, and ``MirroredCloudKitSchemaTests``
//  fails the moment the model and the record disagree. So a new mirrored
//  entity — or one new column on ``Hike`` — cannot be added without landing on
//  this file, which is where the release step is written down. That is the
//  whole mechanism: a red test and a note, rather than a check nothing can
//  perform.
//
//  It lives in the test bundle rather than in the app because it is a record
//  for whoever ships the build, not behaviour the app has. Nothing reads it at
//  runtime, and the product should not carry it.
//
//  Field names follow `NSPersistentCloudKitContainer`'s own mangling: entity
//  `Hike` is record type `CD_Hike`, attribute `title` is field `CD_title`. The
//  names are recorded unmangled below, because the model is what this file is
//  checked against; the Console is the authority for how they are spelled
//  there, and confirming the mangled spelling is part of the deploy rather
//  than something this file asserts.
//

import Foundation

/// The mirrored half of the schema, written down.
///
/// The unmirrored sidecar — ``HikeLocalState`` — is deliberately absent, and
/// ``MirroredCloudKitSchemaTests`` asserts its absence: a device-local row
/// reaching CloudKit is the bug the store split exists to prevent, so it is
/// worth failing for rather than merely not listing.
enum MirroredCloudKitSchema {
    /// One `@Model` in the mirrored store, as the Console will show it.
    struct RecordType: Equatable, Sendable {
        /// The model type's name. `CD_` prefixed, this is the CloudKit record
        /// type.
        var entity: String
        /// Every stored attribute, sorted. `@Transient` properties are not
        /// here, because they are not in the schema either.
        var attributes: [String]
        /// Every relationship, sorted. A to-one becomes a reference field; a
        /// to-many is carried by the inverse rather than by a field of its
        /// own, which is why these are listed apart from ``attributes``.
        var relationships: [String]
    }

    /// Everything the mirrored store declares today.
    ///
    /// Sorted, and exhaustive: the test compares this against the live
    /// `Schema` built from ``OpenHikesSchemaV3/hikeModels`` field for field.
    static let recordTypes: [RecordType] = [
        RecordType(
            entity: "Hike",
            attributes: [
                "author",
                "autoFollowEnabled",
                "customName",
                "date",
                "difficultyMetersByGrade",
                "distanceMeters",
                "id",
                "isRecording",
                "keywords",
                "photos",
                "rawRoute",
                "route",
                "routeLinePatternID",
                "routeWidth",
                "surfaceMetersByCategory",
                "symbol",
                "tintHex",
                "title",
                "trackDescription",
            ],
            relationships: ["walks"]
        ),
        RecordType(
            entity: "HikeWalk",
            attributes: [
                "activeSeconds",
                "coveredIntervals",
                "endReasonID",
                "endedAt",
                "furthestDistanceMeters",
                "hikeID",
                "id",
                "routeDistanceMeters",
                "startedAt",
            ],
            relationships: ["hike"]
        ),
    ]

    /// The day each record type's shape was promoted to the production schema
    /// in the CloudKit Console, as `yyyy-MM-dd`.
    ///
    /// **Empty means nothing has been deployed.** That is the current state
    /// and it is recorded rather than assumed: no entry here has been made,
    /// so every type in ``recordTypes`` is still development-only and a build
    /// reaching TestFlight external testing or the App Store today would fail
    /// to export the walker's first walk.
    ///
    /// A deploy covers the container's whole development schema at the moment
    /// the button is pressed, so promoting after adding a column means every
    /// entry here moves to that day's date together. Adding an entry is a
    /// claim about something that happened in a browser, which nothing in this
    /// repository can verify — so make it in the same change that does it, and
    /// confirm in the Console that each record type below is present in
    /// **Production** with every field the model declares before writing the
    /// date down.
    static let productionDeployments: [String: String] = [:]

    /// The record types carried by the current model that have not been
    /// recorded as promoted to production.
    ///
    /// Not an assertion — a build under development is expected to be here,
    /// and CI cannot know whether the next build is the one that ships. It is
    /// what the test reports in its failure message so the list is legible at
    /// the moment somebody is already looking at this file.
    static var pendingProductionDeployment: [String] {
        recordTypes
            .map(\.entity)
            .filter { productionDeployments[$0] == nil }
            .sorted()
    }
}
