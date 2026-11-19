//
//  StubVectorTileManifests.swift
//  OpenHikesTests
//
//  The tile server's manifest as a suite chooses it, counting how often it
//  is read, and manifests to answer with.
//

import Foundation
@testable import OpenHikes
import Synchronization

/// Answers every read with the manifest it holds, or fails where it holds
/// none, as a server that cannot be reached does.
nonisolated final class StubVectorTileManifests: VectorTileManifestServing {
    private struct State {
        var answer: VectorTileArchiveManifest?
        var reads = 0
    }

    private let state: Mutex<State>

    init(_ answer: VectorTileArchiveManifest?) {
        state = Mutex(State(answer: answer))
    }

    var reads: Int { state.withLock { $0.reads } }

    func answer(with manifest: VectorTileArchiveManifest?) {
        state.withLock { $0.answer = manifest }
    }

    @concurrent
    func manifest() async throws -> VectorTileArchiveManifest {
        let answer = state.withLock { state in
            state.reads += 1
            return state.answer
        }
        guard let answer else { throw URLError(.cannotConnectToHost) }
        return answer
    }
}

nonisolated extension VectorTileArchiveManifest {
    /// One basemap this build draws, and the extras named, at `revision`.
    static func fixture(revision: Int, basemap: String, extras: String? = nil) -> Self {
        Self(
            version: currentVersion,
            revision: revision,
            basemaps: [.init(name: basemap, schema: OfflineCountryManifest.readableSchema, maximumZoom: 15)],
            extras: extras.map { [.init(name: $0, generation: extrasGeneration, minimumZoom: 14)] } ?? []
        )
    }
}
