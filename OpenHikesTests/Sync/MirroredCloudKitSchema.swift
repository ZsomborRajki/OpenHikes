//
//  MirroredCloudKitSchema.swift
//  OpenHikesTests
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
    /// `Schema` built from ``OpenHikesSchema/hikeModels`` field for field.
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
}
