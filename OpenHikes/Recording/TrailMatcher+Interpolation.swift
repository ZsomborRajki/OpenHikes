//
//  TrailMatcher+Interpolation.swift
//  OpenHikes
//
//  Builds RecordingPoint arrays interpolated along matched route coordinates.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated extension TrailMatcher {
    struct InterpolationContext {
        let coordinates: [CLLocationCoordinate2D]
        let distances: [Double]
        let total: Double
        let duration: TimeInterval
        let start: RecordingPoint
        let end: RecordingPoint
        let carriesNonPedestrianMotion: Bool
        /// Whether Core Motion called both ends of an observed segment
        /// stationary, so the points interpolated between them should say so
        /// too.
        ///
        /// ``RecordingDistanceAccumulator`` is the only reader, and it treats
        /// a *run* of stationary fixes as evidence — one unflagged point ends
        /// the run. Interpolating a matched leg multiplies two fixes into a
        /// dozen points, so without this the run never survives matching and
        /// the saved distance keeps a stationary window the live readout
        /// retracted. Never set across an inferred segment: nothing was
        /// observed between those two fixes, so a stationary verdict at each
        /// end says nothing about the walk between them.
        let carriesMotionStationary: Bool
        /// Whether this whole segment spans ground the recording never
        /// observed — see ``RecordingPointFlags/inferred``.
        let isInferred: Bool
    }

    static func recordingPoints(
        along rawCoordinates: [CLLocationCoordinate2D],
        from start: RecordingPoint,
        to end: RecordingPoint,
        inferred: Bool = false
    ) -> [RecordingPoint] {
        var coordinates: [CLLocationCoordinate2D] = []
        for coordinate in [start.coordinate] + rawCoordinates + [end.coordinate] {
            guard let previous = coordinates.last else {
                coordinates.append(coordinate)
                continue
            }
            if RouteGeometry.distanceMeters(from: previous, to: coordinate)
                > minimumCoordinateDistanceMeters {
                coordinates.append(coordinate)
            }
        }
        if coordinates.count < 2 {
            coordinates = [start.coordinate, end.coordinate]
        }
        // Running total along the route; `distances[i]` is how far along the
        // route `coordinates[i]` sits.
        let distances = coordinates.adjacentPairs().reductions(0.0) { travelled, leg in
            travelled + RouteGeometry.distanceMeters(from: leg.0, to: leg.1)
        }
        let ctx = InterpolationContext(
            coordinates: coordinates,
            distances: distances,
            total: distances.last ?? 0,
            duration: end.timestamp.timeIntervalSince(start.timestamp),
            start: start,
            end: end,
            carriesNonPedestrianMotion: start.flags.contains(.nonPedestrian)
                || end.flags.contains(.nonPedestrian),
            carriesMotionStationary: !inferred
                && start.flags.contains(.motionStationary)
                && end.flags.contains(.motionStationary),
            isInferred: inferred
        )
        return coordinates.indices.map { index in
            interpolatedPoint(at: index, context: ctx)
        }
    }

    static func interpolatedPoint(
        at index: Int,
        context: InterpolationContext
    ) -> RecordingPoint {
        let fraction = context.total > 0
            ? context.distances[index] / context.total
            : Double(index) / Double(max(1, context.coordinates.count - 1))
        let elevation: Double?
        if let startElevation = context.start.elevation,
           let endElevation = context.end.elevation {
            elevation = startElevation + (endElevation - startElevation) * fraction
        } else if index == 0 {
            elevation = context.start.elevation
        } else if index == context.coordinates.count - 1 {
            elevation = context.end.elevation
        } else {
            elevation = nil
        }
        var flags: RecordingPointFlags = context.carriesNonPedestrianMotion
            ? [.nonPedestrian]
            : []
        if context.carriesMotionStationary {
            flags.formUnion(.motionStationary)
        }
        // From index 1 onward, never on index 0: the flag describes the
        // stretch arriving at a point, and index 0 is the anchor the *previous*
        // leg's stretch already arrived at.
        if context.isInferred, index > 0 {
            flags.formUnion(.inferred)
        }
        if index == 0 {
            flags.formUnion(context.start.flags)
        } else if index == context.coordinates.count - 1 {
            flags.formUnion(context.end.flags)
        }
        return RecordingPoint(
            latitude: context.coordinates[index].latitude,
            longitude: context.coordinates[index].longitude,
            timestamp: context.start.timestamp.addingTimeInterval(
                context.duration * fraction
            ),
            horizontalAccuracy: context.start.horizontalAccuracy
                + (context.end.horizontalAccuracy - context.start.horizontalAccuracy)
                    * fraction,
            elevation: elevation,
            course: index == 0
                ? context.start.course
                : (index == context.coordinates.count - 1 ? context.end.course : nil),
            speed: index == 0
                ? context.start.speed
                : (index == context.coordinates.count - 1 ? context.end.speed : nil),
            flags: flags
        )
    }
}
