//
//  ScriptedRecordWriter.swift
//  OpenHikesTests
//
//  The seam under the real transport, scripted — what lets a suite fail the
//  second of an upload's two saves and nothing else.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Synchronization

/// A `CommunityRecordWriting` that answers from a script and remembers what it
/// was asked to save.
///
/// It stands in for the public database, which no suite may reach: a record
/// saved from a test run is a record every user can see, and it cannot be
/// taken back. A stub standing in for the *whole* transport cannot do this
/// job — it can fail an upload or succeed at one, but the case that used to
/// lose a submission is the one where the first save lands and the second
/// does not, and that boundary is inside the transport. Under it, the real
/// `submit` runs, the real records are built, and the script refuses exactly
/// the save a suite wants refused.
nonisolated final class ScriptedRecordWriter: CommunityRecordWriting {
    /// What one save carried, copied out of the record while it was in hand.
    ///
    /// A snapshot rather than the `CKRecord`s themselves, so a suite reads it
    /// from the main actor without holding anything the framework does not
    /// promise is safe to share.
    nonisolated struct Saved: Equatable, Sendable {
        let recordType: String
        let recordName: String
        /// Each reference field, mapped to the name of the record it points at.
        let references: [String: String]
        /// The fields that carry an uploaded file.
        let assetFields: Set<String>

        init(_ record: CKRecord) {
            var foundReferences: [String: String] = [:]
            var foundAssets: Set<String> = []
            for key in record.allKeys() {
                let value = record[key]
                if let reference = value as? CKRecord.Reference {
                    foundReferences[key] = reference.recordID.recordName
                } else if value is CKAsset || value is [CKAsset] {
                    foundAssets.insert(key)
                }
            }
            recordType = record.recordType
            recordName = record.recordID.recordName
            references = foundReferences
            assetFields = foundAssets
        }
    }

    nonisolated private struct State {
        var saved: [Saved] = []
        var script: [CKError?]
        var status: CKAccountStatus
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - script: One entry per save, in order: the error to refuse that save
    ///     with, or `nil` to accept it. Past the end of it every save is
    ///     accepted, so a suite scripts only the saves it wants to go wrong.
    ///   - accountStatus: What the account check answers.
    init(script: [CKError?] = [], accountStatus: CKAccountStatus = .available) {
        state = Mutex(State(script: script, status: accountStatus))
    }

    /// Every save that was asked for, in order — the refused ones included,
    /// because a refused save is still a save that was attempted, and "the
    /// notice was tried and failed" is the half of the story a suite is here
    /// to see.
    var saved: [Saved] {
        state.withLock { $0.saved }
    }

    @concurrent
    func accountStatus() async -> CKAccountStatus {
        state.withLock { $0.status }
    }

    @concurrent
    func save(_ record: CKRecord) async throws -> CKRecord {
        let snapshot = Saved(record)
        let refusal = state.withLock { held -> CKError? in
            held.saved.append(snapshot)
            return held.script.isEmpty ? nil : held.script.removeFirst()
        }
        if let refusal { throw refusal }
        return record
    }
}
