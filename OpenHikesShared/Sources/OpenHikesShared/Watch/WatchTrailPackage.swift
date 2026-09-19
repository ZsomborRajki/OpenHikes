//
//  WatchTrailPackage.swift
//  OpenHikesShared
//
//  The trail as a watch needs it: a line to draw, a length to measure against
//  and enough points to say how far off it somebody is standing.
//
//  ## Why this is not `SharedTrailSnapshot`
//
//  They answer different questions. A snapshot is what the *phone* has already
//  worked out — it carries a `liveFix` the phone matched, a `walk` the phone
//  accrued, and a polyline decimated to 180 points because a widget is a few
//  hundred pixels wide and nothing downstream ever matches against it.
//
//  A watch matches for itself. It is a separate device on the other side of a
//  Bluetooth link, out of reach of `RouteProfile`, `TrailMatcher` and the App
//  Group all three, so the geometry it is handed is the input to its own
//  arithmetic rather than a picture of somebody else's. At 180 points a 20 km
//  trail has a 110 m stride between them, and an off-route reading taken
//  against that line is noise next to the 75 m threshold it would be compared
//  with. Hence ``pointBudget``, which is an order of magnitude larger, and
//  hence the elevation per point: the watch says what height the *trail* is at
//  the hiker's position, the same figure `SharedTrailSnapshot.LiveFix` carries
//  and for the same reason — GPS vertical noise is not a trail's elevation.
//
//  Reusing the snapshot would have meant growing it for a consumer the widget
//  does not have, on the one payload in this package that is already shipped
//  and versioned. The two are cheap and separate instead, which is the
//  argument `SharedRecordingSnapshot`'s header already makes for itself.
//
//  ## Size
//
//  Arithmetic rather than measurement: a point encodes as roughly 70 bytes of
//  JSON with an elevation, so a full ``pointBudget`` trail is around 55 KB.
//  That is inside what `WCSession.transferUserInfo` will queue happily and is
//  why the budget is 800 rather than the whole route — a recorded walk can
//  carry tens of thousands of points, and none of them would be drawn.
//

import Foundation

/// One point of the trail line, as the watch draws and matches against it.
public struct WatchTrailPoint: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// The trail's own height here, where the route carried one.
    public var elevationMeters: Double?

    public init(latitude: Double, longitude: Double, elevationMeters: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevationMeters = elevationMeters
    }

    /// The drawing-side spelling of the same place, so a package can be handed
    /// straight to ``TrailGlyphView`` without a second coordinate type.
    public var coordinate: SharedTrailSnapshot.CodableCoordinate {
        SharedTrailSnapshot.CodableCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// A trail the phone has sent to the watch.
public struct WatchTrailPackage: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    /// How many points of a route cross to the watch. See this file's header
    /// for why it is not the widget's 180 and not the whole route.
    public static let pointBudget = 800

    public let schemaVersion: Int

    public var hikeID: UUID
    /// The name the hiker has seen, already resolved — a renamed hike's
    /// `customName` rather than what the GPX called it, the same way
    /// ``SharedHikeSummary`` carries one name.
    public var title: String
    public var tintHex: String
    /// The trail's length on the hiker's own scale — `Hike.distanceMeters`,
    /// not the summed length of the decimated line below.
    ///
    /// The two are different numbers and the difference is the whole reason
    /// this is carried separately: dropping points shortens a line, so a watch
    /// that measured progress against what it was sent would tell a hiker a
    /// trail was shorter than the phone says it is. ``WatchRouteTracker``
    /// measures along the line it has and reports on this scale.
    public var totalDistanceMeters: Double
    public var elevationGainMeters: Double?
    public var elevationLossMeters: Double?
    public var points: [WatchTrailPoint]
    public var sentAt: Date

    public init(
        hikeID: UUID,
        title: String,
        tintHex: String,
        totalDistanceMeters: Double,
        points: [WatchTrailPoint],
        elevationGainMeters: Double? = nil,
        elevationLossMeters: Double? = nil,
        sentAt: Date = .now
    ) {
        self.hikeID = hikeID
        self.title = title
        self.tintHex = tintHex
        self.totalDistanceMeters = totalDistanceMeters
        self.points = points
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.sentAt = sentAt
        schemaVersion = Self.currentSchemaVersion
    }

    /// Whether there is enough here to measure against. One point is a place,
    /// not a line, and every consumer of this type wants a line.
    public var isDrawable: Bool { points.count > 1 }

    /// The line, in the coordinate type the shared drawing code takes.
    public var polyline: [SharedTrailSnapshot.CodableCoordinate] {
        points.map(\.coordinate)
    }
}

/// The watch asking for one trail's geometry.
///
/// Its own payload rather than a bare `UUID` in the envelope, so the request
/// is versioned like everything else crossing this link and a future field —
/// a point budget the watch picks for itself, say — does not need a second
/// message kind.
public struct WatchTrailRequest: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var hikeID: UUID

    public init(hikeID: UUID) {
        self.hikeID = hikeID
        schemaVersion = Self.currentSchemaVersion
    }
}

/// The hiker's library, as the watch's list of trails to choose from.
///
/// Carries ``SharedHikeSummary`` rows — the same four fields the widget's
/// picker and Siri already read — because a watch list shows exactly what a
/// picker row shows. It is deliberately **not** the routes: see
/// ``SharedHikeCatalogue``, whose header makes this argument for the App
/// Group, and which applies with more force over a Bluetooth link.
public struct WatchLibraryDigest: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    /// How many trails cross. A watch list is scrolled with a finger on a
    /// 45 mm screen, and a library can hold years of walks; the phone sends
    /// the newest of them, which is the order ``SharedHikeCatalogue`` is
    /// already sorted in and the same argument `HikeEntityQuery` makes for its
    /// suggestion limit.
    public static let hikeBudget = 50

    public let schemaVersion: Int
    public var hikes: [SharedHikeSummary]
    public var sentAt: Date

    public init(hikes: [SharedHikeSummary], sentAt: Date = .now) {
        self.hikes = hikes
        self.sentAt = sentAt
        schemaVersion = Self.currentSchemaVersion
    }

    public static let empty = Self(hikes: [], sentAt: .distantPast)
}
