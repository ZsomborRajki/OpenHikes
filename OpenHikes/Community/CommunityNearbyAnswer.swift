//
//  CommunityNearbyAnswer.swift
//  OpenHikes
//
//  What a nearby question is allowed to ask, and what the OpenStreetMap half
//  of one came back with.
//
//  Both halves of that exist for the same reason: Overpass is a volunteer-run
//  API with a handful of slots per address, and this app is one of thousands
//  asking. A `429` there is not an exotic condition — it is the ordinary
//  weather — so the two things the community list has to be able to do about
//  it are *ask only where a hiker is asking* and *say what came back*.
//
//  ## Who asks
//
//  ``CommunityNearbyScope`` is the question's own answer to "which sources".
//  Before it, every nearby request reached both, refills and retries included,
//  each costing two Overpass round trips on top of the CloudKit query for a
//  question nobody had put. Now the rule is about *who asked*: a hiker
//  arriving at the trails gets them — selecting the *Community* tab, tapping
//  *Search this area*, tapping *Try Again* — and the requests the app makes on
//  its own behalf, a refill after a block above all, run on the published
//  hikes alone.
//
//  Opening the tab is on the asking side and was briefly on the other. The
//  argument for making the tab published-only was that one selection should
//  not spend two Overpass round trips on a question nobody typed; what it cost
//  was the feature itself. The *Community* tab **is** the trails, so a list
//  that opened without them opened looking empty in exactly the areas the
//  trails would have filled, and the tap that fixed it spent a second CloudKit
//  query to ask the same question again. One selection is one search.
//
//  The scope travels as a parameter rather than as a mode on the transport
//  because the transport is a `Sendable` value shared by every caller, and a
//  flag set on it would be a flag two in-flight requests could disagree about.
//
//  ## What comes back
//
//  ``CuratedTrailOutcome`` is what the curated half amounts to, carried back
//  beside the rows rather than thrown. ``MergedCommunityTransport`` has always
//  caught its failures — one source failing is not the answer failing, and a
//  `429` from Overpass must never draw *These are the hikes from the last
//  search that worked* over a perfectly good CloudKit list — and what this
//  type adds is that catching them is no longer *all* it does.
//
//  There are three answers and they are three different sentences:
//
//  - **Nothing was asked.** A published-only question has nothing to say about
//    OpenStreetMap, and must not be able to clear something a question that
//    did ask put on screen.
//  - **Trails, or none.** An area with no waymarked day hikes in it is a real
//    answer and used to be a silent one: the list said *No community hikes
//    here*, the caption under the button said nothing at all, and a hiker who
//    had just spent a search could not tell that from a search that had not
//    run. It now says so, which is also the sentence that tells them to try
//    somewhere else.
//  - **An outage.** ``CuratedTrailOutage``, which is a failure and reads like
//    one. A hiker whose address is rate-limited is looking at a list missing
//    half its sources, and the only place that used to be visible was
//    Console.app.
//
//  The last two are *reported and not raised*: the request succeeded, the list
//  is real, and what is being described is one of its two sources. That is a
//  different sentence from ``CommunityFailure``'s, and it is drawn somewhere
//  different — beside the control that spends the request rather than over the
//  rows, which are not in doubt.
//

import Foundation

/// Which sources a nearby question reaches.
///
/// The published hikes are always asked; what this decides is whether
/// OpenStreetMap is asked alongside them. See this file's header for why the
/// distinction is a parameter on the question rather than a setting anywhere.
nonisolated enum CommunityNearbyScope: Equatable, Sendable {
    /// The app's own published hikes, and nothing else.
    ///
    /// What a request the hiker did not make costs: one CloudKit query. The
    /// refill after a block is the one that matters — a block is not somebody
    /// asking OpenStreetMap anything, and the curated rows in the list are
    /// unaffected by one, since an OSM relation has no author to block.
    case publishedOnly
    /// The published hikes and the curated OpenStreetMap routes beside them.
    ///
    /// Two Overpass round trips on top of the CloudKit query — a listing pass
    /// and a geometry pass — so the things that ask for it are the things a
    /// hiker does to look for trails: opening the *Community* tab, *Search
    /// this area*, and the *Try Again* that stands in for it when a search has
    /// failed.
    case withCuratedTrails
}

/// Why there are no OpenStreetMap trails in an answer that asked for them.
///
/// Deliberately not a ``CommunityFailure``. That type is the answer to *did
/// the community list work*, and every case of it is drawn over the rows; this
/// is the answer to *and did the other half arrive*, which is a smaller thing
/// that must not disown a list the hiker can use.
nonisolated enum CuratedTrailOutage: Equatable, Sendable {
    /// Overpass asked us to stop for a while, and for how long.
    ///
    /// The interval is what was left at the moment the answer landed rather
    /// than a deadline, because nothing here holds a clock and the figure is
    /// only ever read straight away — every later tap is refused by
    /// ``CuratedTrailSource``'s own check, which recomputes it against a clock
    /// it does hold.
    case rateLimited(retryAfter: TimeInterval)
    /// Anything else: no network, a timeout, or the HTML error page an
    /// overloaded Overpass mirror serves with a `200`.
    case unavailable

    /// The outage `error` amounts to, or `nil` when it is not one to report.
    ///
    /// A cancellation is the `nil`, and it is the case worth spelling out: a
    /// superseded search cancels the curated half mid-flight, and reporting
    /// that as an outage would put *rate-limited* under the button because the
    /// hiker panned twice quickly.
    init?(_ error: any Error) {
        if error is CancellationError { return nil }
        guard let overpass = error as? TrailGraphProviderError,
              case .rateLimited(let retryAfter) = overpass
        else {
            self = .unavailable
            return
        }
        self = .rateLimited(retryAfter: retryAfter)
    }

    /// One short line for beside the *Search this area* button.
    ///
    /// Short because of where it is drawn — a caption under a pill, over map
    /// imagery, at whatever text size the hiker has chosen — and it names
    /// OpenStreetMap because naming the half that is missing is the whole
    /// point. The community hikes are in the list underneath, and the sentence
    /// has to be one that does not cast doubt on them.
    var text: String {
        switch self {
        case .rateLimited(let retryAfter):
            guard let wait = Self.wait(retryAfter) else {
                return String(localized: "OpenStreetMap trails rate-limited")
            }
            return String(localized: "OpenStreetMap trails rate-limited · \(wait)")
        case .unavailable:
            return String(localized: "OpenStreetMap trails unavailable")
        }
    }

    /// `retryAfter` as "1 min", or `nil` once there is nothing left to wait.
    ///
    /// One unit rather than two: *1 min, 0 sec* is the formatter's honest
    /// answer to a `Retry-After: 60` and is not a thing to put on a pill.
    /// Rounded up, so a wait is never reported as already over.
    private static func wait(_ retryAfter: TimeInterval) -> String? {
        guard retryAfter > 0 else { return nil }
        return Duration.seconds(Int(retryAfter.rounded(.up)))
            .formatted(
                .units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
            )
    }
}

/// The caption under *Search this area*: what the last search that asked
/// OpenStreetMap has to say for itself.
///
/// Two kinds of sentence rather than one, because they ask different things of
/// the hiker. An outage is a failure and is drawn as one, with the warning
/// glyph the list's own failure rows use — the answer to it is to wait. An
/// empty area is not a failure at all and must not wear that glyph: nothing is
/// broken, the search worked, and the answer to it is to look somewhere else.
/// Drawing both as warnings would be the same flattening this type exists to
/// undo — it is what made *OpenStreetMap trails unavailable* the only thing a
/// hiker ever saw under that button.
nonisolated enum CuratedTrailNotice: Equatable, Sendable {
    /// OpenStreetMap answered, and there are no waymarked day hikes here.
    case noTrailsHere
    /// OpenStreetMap could not be reached, or asked us to wait.
    case outage(CuratedTrailOutage)

    /// The line itself. See ``CuratedTrailOutage/text`` on why it is short and
    /// why it names OpenStreetMap.
    var text: String {
        switch self {
        case .noTrailsHere:
            String(localized: "No OpenStreetMap trails here — try another area")
        case .outage(let outage):
            outage.text
        }
    }

    /// The glyph beside it, which is the whole of the difference on screen at
    /// a glance.
    var symbolName: String {
        switch self {
        case .noTrailsHere: "mappin.slash"
        case .outage: "exclamationmark.triangle.fill"
        }
    }

    /// Whether this is something that went wrong, which is what decides the
    /// glyph's colour: a warning is orange, an answer is not coloured at all.
    var isWarning: Bool {
        switch self {
        case .noTrailsHere: false
        case .outage: true
        }
    }
}

/// What the OpenStreetMap half of a nearby answer came to.
///
/// One value with three cases rather than an optional outage beside a count,
/// because two fields would be two things a caller could read in disagreement
/// — *rate-limited* and *nothing here* are not both true, and *not asked* is
/// neither. See this file's header for what each one is a sentence about.
nonisolated enum CuratedTrailOutcome: Equatable, Sendable {
    /// The question did not ask about OpenStreetMap, so there is nothing to
    /// report and nothing on screen to clear.
    case notAsked
    /// The listing pass, or the geometry pass behind it, could not be made.
    case outage(CuratedTrailOutage)
    /// The listing pass answered, with this many routes near the area.
    ///
    /// The count is what **Overpass listed**, not how many rows the answer
    /// ends up carrying: the merge spends the page on published hikes first
    /// and drops whatever the limit has no room for — see
    /// ``MergedCommunityTransport/merge(published:curated:limit:)``. Counting
    /// the rows instead would report an area full of trails as empty on the
    /// day twenty-five people published hikes in it.
    case trails(Int)

    /// What to draw beside *Search this area*, or `nil` when the answer is one
    /// nobody needs a sentence about.
    ///
    /// Trails that arrived are the `nil` worth naming: they are in the list,
    /// which is where a hiker reads them, and a caption saying so would be a
    /// label on a working screen.
    var notice: CuratedTrailNotice? {
        switch self {
        case .notAsked:
            nil
        case .outage(let outage):
            .outage(outage)
        case .trails(let count):
            count == 0 ? .noTrailsHere : nil
        }
    }
}

/// A nearby answer: the rows, and what the curated half had to say for itself.
///
/// A type rather than a tuple because it crosses the transport seam, and
/// because the second field is the one a reader has to be able to find: a
/// caller that ignores it draws exactly what it drew before, which is the sort
/// of omission a tuple's `.1` hides.
nonisolated struct CommunityNearbyAnswer: Equatable, Sendable {
    /// The published hikes and, when the question asked for them, the curated
    /// routes — already merged, ordered and budgeted. See
    /// ``MergedCommunityTransport``.
    var listings: [CommunityListing]
    /// What the OpenStreetMap half of this answer amounts to.
    ///
    /// ``CuratedTrailOutcome/notAsked`` by default, which is the honest answer
    /// for every conformance with one source behind it — see
    /// ``CloudKitCommunityTransport`` — and for a title search, which has no
    /// curated half to ask.
    var curated: CuratedTrailOutcome

    init(listings: [CommunityListing], curated: CuratedTrailOutcome = .notAsked) {
        self.listings = listings
        self.curated = curated
    }
}
