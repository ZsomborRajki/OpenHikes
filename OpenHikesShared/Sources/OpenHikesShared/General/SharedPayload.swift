//
//  SharedPayload.swift
//  OpenHikesShared
//

import Foundation

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

/// Why a versioned payload's bytes were not handed back.
///
/// Public for the watch's own files, which its target reads through
/// ``WatchStoredFile``. The App Group and the watch link turn it into their
/// own diagnostics.
public enum SharedPayloadReadFailure: Error, Equatable, Sendable {
    /// The bytes are not the current format's shape. `detail` names the key
    /// and its coding path.
    case malformed(detail: String)
    /// The bytes announce a format this build does not read.
    case unsupportedVersion(found: Int, supported: Int)
}

extension SharedPayload {
    /// Reads only the current format, refusing any other before a field is
    /// interpreted.
    ///
    /// The one version check every boundary uses — the App Group, the watch
    /// link and the watch's own disk — so bytes are held to the same contract
    /// whichever way they arrived. An exact match, not a minimum: a format is
    /// never migrated, only refused (*Schema and migration policy*).
    static func decodeCurrentFormat(from data: Data) throws(SharedPayloadReadFailure) -> Self {
        let announced = (try? JSONDecoder().decode(SharedPayloadVersionPeek.self, from: data))?.schemaVersion
        if let announced, announced != currentSchemaVersion {
            throw .unsupportedVersion(found: announced, supported: currentSchemaVersion)
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw .malformed(detail: SharedStoreDiagnostics.describe(error))
        }
    }
}
