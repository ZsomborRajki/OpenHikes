//
//  SharedHikeCatalogue.swift
//  OpenHikesShared
//
//  The list of a hiker's saved trails, in the App Group, so a process with no
//  SwiftData store can offer them.
//
//  ## Why this has to exist
//
//  The widget's configuration picker runs in **OpenWidgetExtension**, which
//  has no `ModelContainer`, no registered `AppDependencyManager` dependency
//  and no `Hike` to fetch. A picker backed by the app's store cannot run
//  there at all: `HikeIntentCoordinator` is registered by `OpenHikesApp.init`
//  in the *app* process, and asking `AppDependencyManager` for a dependency
//  that was never registered traps rather than returning `nil`.
//
//  So the widget needs a list it can read from a file, and this is it. Four
//  fields per hike — identifier, name, date, distance — which is exactly what
//  a picker row shows and nothing more. **Not the route**: a catalogue of
//  three hundred routes would be megabytes rewritten on every edit, and what
//  a widget needs a route for is covered by the per-hike trail snapshots in
//  ``SharedStore`` instead.
//
//  ## Why the app reads it too
//
//  Because two lists is how they come to disagree. The same catalogue answers
//  Siri in the app process, which also makes those lookups cheaper — no
//  `ModelContext` fetch, no main-actor hop — and removes the one place a
//  missing dependency could trap. The app writes it whenever its hikes change;
//  see the catalogue publisher in the app target.
//
//  ## Staleness is a property of the thing, not a bug
//
//  A catalogue is a copy, and a copy is behind. A hike renamed a moment ago
//  may be offered under its old name until the next write lands, and a hike
//  deleted a moment ago may still be offered — which is why every consumer
//  resolves the identifier against the real store before acting on it, and
//  why ``SharedStore/loadTrailSnapshot(for:)`` answering `nil` is drawn as a
//  widget with nothing to show rather than treated as an error.
//

import Foundation

/// One saved hike, as a picker row.
public struct SharedHikeSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The name the hiker has actually seen — a renamed hike's `customName`
    /// rather than whatever the import called it. The app is what resolves
    /// that; by the time it reaches here there is one name.
    public let name: String
    public let date: Date
    /// Metres, as a plain `Double` rather than an encoded `Measurement`: this
    /// is read back by a different binary, and the bytes must not depend on
    /// how Foundation happens to serialize a unit.
    public let distanceMeters: Double
    /// `nil` for a hike whose route carries no usable timestamps, which is
    /// most imported GPX. Optional because the fact is.
    public let durationSeconds: TimeInterval?

    public init(
        id: UUID,
        name: String,
        date: Date,
        distanceMeters: Double,
        durationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }
}

/// Every saved hike, newest first.
public struct SharedHikeCatalogue: Codable, Equatable, Sendable {
    /// Newest first, which is the order a picker offers them in and the order
    /// ``suggestions(limit:)`` takes its prefix from. Sorted by the writer so
    /// no reader has to.
    public let hikes: [SharedHikeSummary]
    /// When the app last wrote this. Carried for diagnostics rather than for
    /// any decision: nothing here expires, because a stale list is still a
    /// better picker than no picker.
    public let writtenAt: Date

    public init(hikes: [SharedHikeSummary], writtenAt: Date = .now) {
        self.hikes = hikes
        self.writtenAt = writtenAt
    }

    public static let empty = Self(hikes: [], writtenAt: .distantPast)
}

public extension SharedHikeCatalogue {
    /// The hikes with these identifiers, in the catalogue's own order.
    ///
    /// Order is the catalogue's rather than the argument's, deliberately: the
    /// system asks for a set of identifiers and draws the answer as a list,
    /// and newest-first is the only ordering this has any reason to claim.
    func hikes(withIDs identifiers: [UUID]) -> [SharedHikeSummary] {
        let wanted = Set(identifiers)
        return hikes.filter { wanted.contains($0.id) }
    }

    /// The hikes whose names match `text`, for the spoken half.
    ///
    /// Case- and diacritic-insensitive containment rather than a ranking:
    /// ``HikeNameMatch`` in the app is the real matcher and this cannot import
    /// it, so what this does is deliberately the weaker, obvious thing. A
    /// picker offering one row too many is recoverable; a clever ranking that
    /// disagrees with the app's search is two answers to one question.
    func hikes(matching text: String) -> [SharedHikeSummary] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hikes }
        return hikes.filter { hike in
            hike.name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    /// What a picker offers before anything has been typed.
    ///
    /// Recent ones, because a hike somebody wants to name is overwhelmingly
    /// one they did lately — the same argument `HikeEntityQuery` made for its
    /// own suggestion limit.
    func suggestions(limit: Int) -> [SharedHikeSummary] {
        Array(hikes.prefix(max(0, limit)))
    }
}
