//
//  SharedRecordingSnapshot.swift
//  OpenHikesShared
//
//  The live recording payload shared by the app and widget. It is deliberately
//  separate from SharedTrailSnapshot so the shipped trail contract stays
//  stable and neither target has to reinterpret one payload as the other.
//

import Foundation

public struct SharedRecordingSnapshot: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var startedAt: Date
    public var distanceMeters: Double
    public var pointCount: Int
    /// Cumulative climb so far, summed between consecutive accepted fixes
    /// that carried a trusted altitude. `nil` until the recording has two of
    /// them — one fix is a height, not a change.
    public var elevationGainMeters: Double?
    /// Distance over the time actually spent recording, so a lunch stop
    /// doesn't drag down the pace of the walk either side of it.
    public var averageSpeedMetersPerSecond: Double?
    public var polyline: [SharedTrailSnapshot.CodableCoordinate]
    public var isCapturingFixes: Bool
    public var updatedAt: Date

    public init(
        sessionID: UUID,
        startedAt: Date,
        distanceMeters: Double,
        pointCount: Int,
        polyline: [SharedTrailSnapshot.CodableCoordinate],
        elevationGainMeters: Double? = nil,
        averageSpeedMetersPerSecond: Double? = nil,
        isCapturingFixes: Bool = true,
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.distanceMeters = distanceMeters
        self.pointCount = pointCount
        self.elevationGainMeters = elevationGainMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.polyline = polyline
        self.isCapturingFixes = isCapturingFixes
        self.updatedAt = updatedAt
    }

    public var title: String {
        isCapturingFixes ? "Recording Hike" : "Recording Paused"
    }

    public var statusText: String {
        "\(WidgetFormat.length(meters: distanceMeters)) · \(pointCount.formatted()) pts"
    }
}
