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
    public var polyline: [SharedTrailSnapshot.CodableCoordinate]
    public var isCapturingFixes: Bool
    public var updatedAt: Date

    public init(
        sessionID: UUID,
        startedAt: Date,
        distanceMeters: Double,
        pointCount: Int,
        polyline: [SharedTrailSnapshot.CodableCoordinate],
        isCapturingFixes: Bool = true,
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.distanceMeters = distanceMeters
        self.pointCount = pointCount
        self.polyline = polyline
        self.isCapturingFixes = isCapturingFixes
        self.updatedAt = updatedAt
    }

    public var title: String {
        isCapturingFixes ? "Recording Hike" : "Recording Paused"
    }

    public var statusText: String {
        let distance = Measurement(value: distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return "\(distance) · \(pointCount.formatted()) pts"
    }
}
