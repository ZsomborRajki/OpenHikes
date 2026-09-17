//
//  SharedPayload.swift
//  OpenHikesShared
//

/// The current wire format shared by the app and widget.
/// See "Schema and migration policy" in the repository instructions.
protocol SharedPayload: Codable, Sendable {
    static var currentSchemaVersion: Int { get }
    // periphery:ignore - never read through the protocol, and load bearing
    // anyway: it is what makes every conformer synthesise the encoded
    // `schemaVersion` key that `SharedPayloadVersionPeek` reads back off the
    // raw bytes, before any field is interpreted.
    var schemaVersion: Int { get }
}

/// Checks the format before interpreting any payload fields.
struct SharedPayloadVersionPeek: Decodable {
    var schemaVersion: Int
}
