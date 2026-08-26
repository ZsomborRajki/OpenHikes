//
//  RouteArchive.swift
//  OpenHikes
//
//  How a route's points are packed for the trip to iCloud, and unpacked on the
//  way back.
//
//  Compressed, because a route is the only part of a hike with no upper bound
//  on its size and it is the part that repeats: consecutive fixes on the same
//  walk share every leading digit of their latitude, longitude and timestamp,
//  which is exactly what zlib is for. A day's recording of some twenty
//  thousand points is a couple of megabytes as JSON and a couple of hundred
//  kilobytes after this — the difference between a sync that finishes on a
//  trailhead's cellular signal and one that doesn't, and between a shelf of
//  hikes costing a user a noticeable slice of their iCloud storage and costing
//  them almost none of it.
//
//  A separate type rather than a couple of lines inside the record mapping so
//  that the one property this whole feature depends on — that what comes back
//  out is what went in — is a test rather than an assumption.
//

import Foundation

/// Packs and unpacks ``RouteCoordinate`` arrays for transport.
nonisolated enum RouteArchive {
    /// Bumped only if the encoding itself changes shape. It rides along in the
    /// record so that a future reader can tell "written by a version I don't
    /// understand" apart from "corrupt", and refuse rather than guess.
    static let version = 1

    enum Failure: Error, Equatable {
        case decodingFailed
        case encodingFailed
        case unsupportedVersion(Int)
    }

    /// JSON rather than a property list because a property list of twenty
    /// thousand near-identical dictionaries spends most of its bytes on an
    /// object table that compresses far worse than the repeated key names JSON
    /// leaves in place. Measured on real recordings, JSON+zlib beats
    /// binary-plist+zlib comfortably — and JSON is the format
    /// ``RouteCoordinate`` already has to round-trip through elsewhere.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ route: [RouteCoordinate]) throws(Failure) -> Data {
        guard let json = try? encoder.encode(route) else {
            throw .encodingFailed
        }
        guard let compressed = Compressor.compress(json) else {
            throw .encodingFailed
        }
        return compressed
    }

    static func decode(
        _ data: Data,
        version: Int = Self.version
    ) throws(Failure) -> [RouteCoordinate] {
        guard version == Self.version else {
            throw .unsupportedVersion(version)
        }
        guard let json = Compressor.decompress(data),
              let route = try? decoder.decode([RouteCoordinate].self, from: json)
        else { throw .decodingFailed }
        return route
    }
}

/// zlib, through `NSData`, because Foundation exposes it nowhere else.
///
/// The `legacy_objc_type` rule is suppressed for the same reason
/// ``HikePhotoStore`` suppresses it for `NSCache`: the Swift-native type has
/// no equivalent API, and the alternative is hand-rolling a `Compression`
/// framework stream buffer for a two-line job.
nonisolated private enum Compressor {
    // swiftlint:disable legacy_objc_type
    static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
    // swiftlint:enable legacy_objc_type
}
