//
//  SharedPayload.swift
//  OpenHikesShared
//

/// The current wire format shared by the app and widget.
/// See "Schema and migration policy" in the repository instructions.
public protocol SharedPayload: Codable, Sendable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }
}

/// Checks the format before interpreting any payload fields.
struct SharedPayloadVersionPeek: Decodable {
    var schemaVersion: Int
}
