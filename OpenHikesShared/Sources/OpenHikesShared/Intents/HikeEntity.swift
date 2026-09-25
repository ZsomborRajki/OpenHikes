//
//  HikeEntity.swift
//  OpenHikesShared
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
//  `HikeSpotlightIndex.donate(from:)`, run from the app's `init()`.
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
//  ## Why it is in the shared package rather than the app
//
//  Because the **widget** needs it. `TrailWidgetConfiguration` takes a
//  `HikeEntity?` so two placed widgets can show two trails (#468), and that
//  intent is compiled into OpenWidgetExtension — where a type in `OpenHikes/`
//  simply does not exist. `project.pbxproj` maps that folder to the app target
//  alone, with `Info.plist` the only membership exception, so this had to move
//  rather than be shared by declaration.
//
//  ## Why the query no longer reads SwiftData
//
//  It could not, in the process that now needs it most. ``HikeEntityQuery``
//  used to resolve the app through `@Dependency var appCoordinator` and hop to
//  the main actor to fetch through a `ModelContext` — and the widget extension
//  has neither the registered dependency nor the store. Asking
//  `AppDependencyManager` for one that was never registered *traps*.
//
//  So the list comes from the App Group instead: ``SharedHikeCatalogue``,
//  which the app republishes whenever its hikes change. One query for both
//  processes rather than two, because two lists of the same hikes is how they
//  come to disagree — and this one is also cheaper in the app, since it is a
//  file read rather than a fetch and a main-actor hop.
//
//  What it costs is freshness: a catalogue is a copy, so a hike renamed a
//  second ago may be offered under its old name. Every consumer resolves the
//  identifier against the real store before acting on it, which is where that
//  is put right.
//
//  ## Not here
//
//  Anything about Apple Intelligence and `AssistantSchemas`. Those
//  conformances are what make an entity usable by the system assistant rather
//  than only by typed shortcuts, and they are worth their own issue now that
//  the entity exists.
//

import AppIntents
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
import Foundation

public struct HikeEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hike"
    public static let defaultQuery = HikeEntityQuery()

    public let id: UUID
    /// The name the hiker has actually seen — see this file's header.
    @Property(title: "Name")
    public var name: String
    @Property(title: "Date")
    public var date: Date
    @Property(title: "Distance")
    public var distance: Measurement<UnitLength>
    /// `nil` for a hike whose route carries no usable timestamps, which is
    /// most imported GPX. Optional because the fact is, rather than for
    /// anybody's convenience.
    @Property(title: "Duration")
    public var duration: TimeInterval?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(Self.subtitle(date: date, distance: distance))"
        )
    }

    /// From the catalogue, which is what the query reads. Metres are stored
    /// as a plain `Double` there for the reason ``SharedHikeSummary`` gives —
    /// the bytes are read by a different binary — and become a `Measurement`
    /// here, where the display formatting wants one.
    public init(_ summary: SharedHikeSummary) {
        id = summary.id
        name = summary.name
        date = summary.date
        distance = Measurement(value: summary.distanceMeters, unit: .meters)
        duration = summary.durationSeconds
    }

    /// The general form, for the app's own construction from a `Hike`.
    public init(
        id: UUID,
        name: String,
        date: Date,
        distance: Measurement<UnitLength>,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.distance = distance
        self.duration = duration
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

#if canImport(CoreSpotlight)
/// Spotlight indexing, conditional because the framework is.
///
/// `IndexedEntity` is CoreSpotlight's, and CoreSpotlight is not in the watchOS
/// SDK at all — not deprecated there, absent, so the import fails to resolve
/// before any member is looked up. The conformance is separated from the type
/// rather than the whole file being excluded because the *entity* is wanted on
/// every platform: `HikeEntityQuery` below is what fills the widget's picker
/// and answers Siri, and a watch that could not name a hike could not offer
/// one either. What a watch loses is a Spotlight index it has no Spotlight to
/// put one in.
extension HikeEntity: IndexedEntity {}
#endif

/// How the system finds a hike: by identifier, by name, or by asking for
/// something to suggest.
///
/// `EntityStringQuery` is the half that matters for voice. Without it Siri can
/// only offer a list to tap, which is the opposite of the argument every
/// intent in the app's Intents folder is built on — the hiker's hands are busy
/// and the phone is in a pocket.
///
/// Backed by ``SharedHikeCatalogue`` rather than by the store, which is what
/// lets the same query fill the widget's configuration picker in a process
/// with no `ModelContainer` — see this file's header for what that replaced
/// and what it costs.
public struct HikeEntityQuery: EntityStringQuery {
    /// How many hikes to offer unprompted.
    ///
    /// A shortcut's parameter picker shows these before anything is typed, and
    /// a list of every walk somebody has ever done is not a suggestion. Recent
    /// ones, because a hike a hiker wants to name is overwhelmingly one they
    /// did lately.
    public static let suggestionLimit = 10

    public init() {
        // Nothing to hold. The catalogue is read on each call rather than
        // cached, because a query object outlives the answer it gave and a
        // list of hikes changes under it.
    }

    /// Synchronous and non-throwing, satisfying requirements that are neither
    /// — which is the change worth noticing. Each of these used to be
    /// `try await MainActor.run { … }` around a `ModelContext` fetch, and a
    /// file read needs neither the hop nor the throw. The widget process has
    /// no main actor worth hopping to for this and no store to throw about.
    public func entities(for identifiers: [UUID]) -> [HikeEntity] {
        SharedStore.loadHikeCatalogue().hikes(withIDs: identifiers).map(HikeEntity.init)
    }

    public func entities(matching string: String) -> [HikeEntity] {
        SharedStore.loadHikeCatalogue().hikes(matching: string).map(HikeEntity.init)
    }

    public func suggestedEntities() -> [HikeEntity] {
        SharedStore
            .loadHikeCatalogue()
            .suggestions(limit: Self.suggestionLimit)
            .map(HikeEntity.init)
    }
}
