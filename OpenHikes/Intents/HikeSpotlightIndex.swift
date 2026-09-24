//
//  HikeSpotlightIndex.swift
//  OpenHikes
//
//  Putting saved hikes where a hiker searching their phone will find them.
//
//  ## Why a launch sweep rather than a donation per save
//
//  Three things change what should be in the index — a hike saved, a hike
//  renamed, a hike deleted — and only the first has an obvious hook. A
//  rename happens in the detail view, a delete in two different places, and an
//  import writes rows through a path that does not know Spotlight exists. Four
//  donation sites that each have to stay correct is how an index comes to
//  disagree with the library.
//
//  A full replace at launch cannot disagree. A hiker's library is tens or
//  hundreds of rows, the whole set is one fetch the intent coordinator already
//  performs, and it runs once per cold launch off the main actor. The cost of
//  being wrong the other way is small and self-correcting: a hike saved this
//  session is searchable next launch.
//
//  ## Why it is behind the test guard
//
//  `CSSearchableIndex` is a real system index on a real device, shared with
//  every other app's results. A hosted unit-test run launches the app against
//  the developer's own store, so an unguarded sweep would push a developer's
//  actual hikes into Spotlight from a test.
//

import AppIntents
import CoreSpotlight
import Foundation
import OpenHikesShared
import os

nonisolated enum HikeSpotlightIndex {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Spotlight")

    /// Replaces the app's Spotlight entries with the current library.
    ///
    /// Fire-and-forget, and silent on failure by design: nothing a hiker does
    /// depends on this having worked, and Spotlight being unavailable is not
    /// something to interrupt a launch over. The log is where the difference
    /// can be read.
    static func donate(from coordinator: HikeIntentCoordinator) {
        Task.detached(priority: .utility) {
            do {
                let entities = try await MainActor.run {
                    try coordinator.finishedHikes().map(HikeEntity.init)
                }
                let index = CSSearchableIndex.default()
                // Deleted before indexed, which is what makes this a replace
                // rather than an accumulation: a hike deleted last session has
                // no other way out of the index.
                try await index.deleteAllSearchableItems()
                guard !entities.isEmpty else { return }
                try await index.indexAppEntities(entities)
            } catch {
                Self.logger.debug(
                    "Spotlight indexing failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
