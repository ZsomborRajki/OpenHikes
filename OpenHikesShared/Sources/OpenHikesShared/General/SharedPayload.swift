//
//  SharedPayload.swift
//  OpenHikesShared
//
//  Versioning for the two payloads the App Group carries between OpenHikes and
//  OpenWidgetExtension.
//
//  Neither payload used to carry a version, and the cost was measured rather
//  than guessed: renaming, retyping or removing any non-optional key made
//  `SharedStore`'s `try?` answer `nil`, which is the same answer it gives for a
//  container that was never written to. The widget drew its placeholder
//  forever, the file stayed intact and valid JSON, and nothing anywhere said
//  why. The version below does not prevent that — a rename still fails to
//  decode — but together with `SharedStoreDiagnostic` it makes every refusal
//  name itself.
//

import Foundation

public protocol SharedPayload: Codable, Sendable {
    /// The version this build writes. Bumped when a change to the payload is
    /// one an older reader must *refuse* rather than tolerate; adding an
    /// optional key is not such a change, and needs no bump.
    static var currentSchemaVersion: Int { get }

    /// The version the bytes on disk were written by, or `nil` when they
    /// predate versioning entirely.
    ///
    /// Optional, and deliberately so. Swift's synthesized `Decodable` does not
    /// fall back to a property's default value for an absent key — it throws —
    /// so a non-optional `schemaVersion` would have made the very update that
    /// introduces versioning discard the perfectly good snapshot already in the
    /// container, blanking every existing user's widget until their next walk.
    /// An absent optional decodes as `nil`, which is the one schema change that
    /// is safe in both directions.
    var schemaVersion: Int? { get }
}

public extension SharedPayload {
    /// The version to judge these bytes by. A payload written before
    /// versioning existed is version 0: it is not unknown, it is the shape
    /// this file's first version was defined against.
    var effectiveSchemaVersion: Int { schemaVersion ?? 0 }
}

/// Reads nothing but the version out of a payload's bytes.
///
/// Peeking before decoding is what separates "written by a build newer than
/// this one" from "written by something this build cannot parse at all". A v2
/// payload need not decode as v1 — and if it partially did, silently accepting
/// it would be worse than refusing it, because the fields v2 gave new meaning
/// would be read with the old one.
struct SharedPayloadVersionPeek: Decodable {
    var schemaVersion: Int?
}
