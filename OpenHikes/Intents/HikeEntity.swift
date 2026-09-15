//
//  HikeEntity.swift
//  OpenHikes
//
//  A saved hike, as something Siri and Spotlight can name.
//
//  ## Why this is not `Hike`
//
//  `Hike` is a `@Model`: main-actor, context-bound, and alive only as long as
//  the `ModelContext` that fetched it. An App Intent runs in a process with no
//  view hierarchy and a system execution budget, and an `AppEntity` is handed
//  around by the system long after the call that produced it. So this is a
//  value lifted off the model, which is the same move ``GPXExport/Track``
//  makes for the same reason — and it is lifted through
//  ``HikeIntentCoordinator``, which is *the whole of what an intent can do*
//  and owns no state. A second path to the store would be another answer kept
//  beside the recorder's.
//
//  ## Why the title is `displayTitle`
//
//  A renamed hike stores its new name in `customName` and leaves `title` at
//  whatever the import called it. ``HikeSearch``'s header argues this at
//  length: ranking on `title` makes a renamed trail unfindable by the only
//  name the hiker has ever seen. Siri has exactly the same problem, and the
//  matching itself is ``HikeNameMatch`` so the two cannot drift.
//
//  ## Spotlight
//
//  ``IndexedEntity`` is the half that gets hikes into Spotlight, which is a
//  bigger win than the Siri phrasing: it costs a conformance and a donation,
//  and it means a hiker who searches their phone for a trail name finds the
//  walk they did on it. The donation is a launch sweep — see
//  ``OpenHikesModel/indexHikesForSpotlight(in:)``.
//
//  ## Why neither type says `nonisolated`
//
//  Almost everything else in this folder does — `SWIFT_DEFAULT_ACTOR_ISOLATION`
//  is `MainActor` here, and a report or a shortcut provider has no business on
//  one. These two are the exception because `@Property` and `@Dependency` are
//  property wrappers, so the things they wrap are *mutable stored properties*,
//  and `nonisolated` cannot be applied to one. Main-actor is also where the
//  work actually happens: the coordinator, the `ModelContext` and every `Hike`
//  it fetches are all main-actor, so the isolation the compiler insists on is
//  the isolation these would have had to hop to anyway.
//
//  ## Not here
//
//  Anything about Apple Intelligence and `AssistantSchemas`. Those
//  conformances are what make an entity usable by the system assistant rather
//  than only by typed shortcuts, and they are worth their own issue now that
//  the entity exists.
//

import AppIntents
import CoreSpotlight
import Foundation

struct HikeEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hike"
    static let defaultQuery = HikeEntityQuery()

    let id: UUID
    /// The name the hiker has actually seen — see this file's header.
    @Property(title: "Name")
    var name: String
    @Property(title: "Date")
    var date: Date
    @Property(title: "Distance")
    var distance: Measurement<UnitLength>
    /// `nil` for a hike whose route carries no usable timestamps, which is
    /// most imported GPX. Optional because the fact is, rather than for
    /// anybody's convenience.
    @Property(title: "Duration")
    var duration: TimeInterval?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(Self.subtitle(date: date, distance: distance))"
        )
    }

    init(_ report: FinishedHikeReport) {
        id = report.id
        name = report.title
        date = report.date
        distance = report.distance
        duration = report.duration
    }

    /// The date and the distance, which is what a row under a trail name says
    /// everywhere else in the app.
    ///
    /// Spelled here rather than reusing ``Hike/subtitle`` because that one is
    /// a member of the model this type exists to avoid touching.
    private static func subtitle(date: Date, distance: Measurement<UnitLength>) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        let length = distance.formatted(
            .measurement(width: .abbreviated, usage: .road)
        )
        return "\(day) · \(length)"
    }
}

/// How the system finds a hike: by identifier, by name, or by asking for
/// something to suggest.
///
/// `EntityStringQuery` is the half that matters for voice. Without it Siri can
/// only offer a list to tap, which is the opposite of the argument every
/// intent in this folder is built on — the hiker's hands are busy and the
/// phone is in a pocket.
struct HikeEntityQuery: EntityStringQuery {
    /// How many hikes to offer unprompted.
    ///
    /// A shortcut's parameter picker shows these before anything is typed, and
    /// a list of every walk somebody has ever done is not a suggestion. Recent
    /// ones, because a hike a hiker wants to name is overwhelmingly one they
    /// did lately.
    private static let suggestionLimit = 10

    @Dependency var appCoordinator: HikeIntentCoordinator

    // `EntityQuery`'s requirements are nonisolated, and everything they need
    // — the coordinator, the `ModelContext`, every `Hike` fetched — is
    // main-actor. So each of these is one hop and a map, and the hop is
    // load-bearing rather than ceremony.
    func entities(for identifiers: [UUID]) async throws -> [HikeEntity] {
        try await MainActor.run {
            try coordinator.finishedHikes(withIDs: identifiers).map(HikeEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [HikeEntity] {
        try await MainActor.run {
            try coordinator.finishedHikes(matchingName: string).map(HikeEntity.init)
        }
    }

    func suggestedEntities() async throws -> [HikeEntity] {
        try await MainActor.run {
            try coordinator
                .finishedHikes()
                .prefix(Self.suggestionLimit)
                .map(HikeEntity.init)
        }
    }

    /// The same `HikeIntentContext` seam every intent in this folder reads
    /// through, so a suite can stand the query up against its own store —
    /// `@Dependency` is filled by the system and is empty in a test.
    private var coordinator: HikeIntentCoordinator {
        HikeIntentContext.override ?? appCoordinator
    }
}
