//
//  OpenHikeIntent.swift
//  OpenHikes
//
//  "Open the Rennsteig in OpenHikes" — one of the two shortcut slots
//  ``OpenHikesShortcuts`` deliberately left unspent.
//
//  The intent is the easy half and ``HikeEntity`` is why: `AppEntity` +
//  `IndexedEntity`, with ``HikeEntityQuery`` conforming to `EntityStringQuery`
//  and already implementing `suggestedEntities()`, so the parameter picker and
//  the spoken matching are already built. What was blocking this was the
//  navigation — see ``HikeOpenRequests``, which is where the argument for
//  routing through the widget's own deep link lives.
//
//  ## Why it performs no work of its own
//
//  `openAppWhenRun` brings the app to the front and this leaves a request
//  behind; the view tree does the rest. Resolving the hike, drawing its route,
//  deciding whether a live recording outranks it — all of that already has an
//  owner, and doing any of it here would be a second copy of a rule that has
//  to keep agreeing with the widget's.
//
//  ## The recording, which this does not special-case
//
//  *A live recording outranks the selected trail, on every surface, without
//  qualification* is settled, and opening a hike is a selection change. This
//  intent does not have to know that: `openHike(id:)` already opens the
//  recording screen for a hike belonging to a live recording, and the widget
//  takeover is decided in ``TrailWidgetEntry`` off the recording payload
//  rather than off what is selected. So the rule is kept by the path this
//  routes through, which is the argument for routing through it.
//

import AppIntents
import Foundation

/// Not `nonisolated`, unlike almost everything else in this folder, and for
/// the reason ``HikeEntity`` gives: `@Parameter` and `@Dependency` are
/// property wrappers, so what they wrap are *mutable stored properties*, and
/// `nonisolated` cannot be applied to one.
struct OpenHikeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Hike"
    static let description = IntentDescription(
        "Opens a saved hike in OpenHikes, with its route on the map.",
        categoryName: "Hikes"
    )
    /// The whole point of the intent: there is nothing to report and
    /// everything to show.
    static let openAppWhenRun = true

    @Parameter(title: "Hike")
    var hike: HikeEntity

    @Dependency var openRequests: HikeOpenRequests

    /// Resolved the way ``HikeCoordinatingIntent`` resolves its coordinator,
    /// and for the same reason: a suite has no registered dependency at all,
    /// and asking for one that was never registered traps rather than
    /// returning `nil`. See ``HikeIntentContext``.
    @MainActor
    private var requests: HikeOpenRequests {
        HikeIntentContext.openRequestsOverride ?? openRequests
    }

    /// `async` with nothing awaited, which the linter is right to notice and
    /// which is load-bearing anyway: `AppIntent.perform()` is declared `async
    /// throws` and is called from outside this actor, so the suspension is
    /// what carries the hop onto the main actor where ``HikeOpenRequests``
    /// lives. `throws` is dropped because nothing here can fail — a hike that
    /// has been deleted since the shortcut was built is ignored by
    /// `openHike(id:)` rather than reported, the same answer the widget gives.
    @MainActor
    func perform() async -> some IntentResult { // swiftlint:disable:this async_without_await
        requests.open(hikeID: hike.id)
        return .result()
    }
}
