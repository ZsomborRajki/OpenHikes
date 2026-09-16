//
//  CommunityNearbyAnswer.swift
//  OpenHikes
//
//  What a nearby question is allowed to ask, and what one came back with when
//  half of it could not be answered.
//
//  Both halves of that are new, and both exist for the same reason: Overpass
//  is a volunteer-run API with a handful of slots per address, and this app is
//  one of thousands asking. A `429` there is not an exotic condition — it is
//  the ordinary weather — so the two things the community list has to be able
//  to do about it are *not ask* and *say so*.
//
//  ## Not asking
//
//  ``CommunityNearbyScope`` is the question's own answer to "which sources".
//  Before it, every nearby request reached both: selecting the *Community*
//  tab, retrying after a failure and refilling the list after a block each
//  cost two Overpass round trips on top of the CloudKit query, none of which
//  the hiker had asked for by name. Now only a tap on *Search this area* asks
//  OpenStreetMap anything, and the rest of the feature runs on the published
//  hikes alone.
//
//  It travels as a parameter rather than as a mode on the transport because
//  the transport is a `Sendable` value shared by every caller, and a flag set
//  on it would be a flag two in-flight requests could disagree about.
//
//  ## Saying so
//
//  ``CuratedTrailOutage`` is the curated half's failure, carried back beside
//  the rows rather than thrown. ``MergedCommunityTransport`` has always caught
//  it — one source failing is not the answer failing, and a `429` from
//  Overpass must never draw *These are the hikes from the last search that
//  worked* over a perfectly good CloudKit list — but catching it was all it
//  did, so the only place the hiker's rate limit was visible was Console.app.
//  A hiker who tapped *Search this area* in the Alps and got no trails had
//  nothing on screen to distinguish that from an area with none in it.
//
//  So the failure is *reported and not raised*: the request succeeded, the
//  list is real, and one of the two sources behind it is briefly missing. That
//  is a different sentence from ``CommunityFailure``'s, and it is drawn
//  somewhere different — beside the control that spends the request rather
//  than over the rows, which are not in doubt.
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
    /// What opening the tab, refilling after a block, and every request the
    /// hiker did not ask for by name now costs: one CloudKit query.
    case publishedOnly
    /// The published hikes and the curated OpenStreetMap routes beside them.
    ///
    /// Two Overpass round trips on top of the CloudKit query — a listing pass
    /// and a geometry pass — which is why exactly one thing in the app asks
    /// for it: the *Search this area* button, and the *Try Again* that stands
    /// in for it when a search has failed.
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
    var notice: String {
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
    /// Why no OpenStreetMap trails are among ``listings``, when that is a
    /// failure rather than an answer.
    ///
    /// `nil` covers three different happy things — the question did not ask
    /// for them, it asked and they arrived, it asked and the area genuinely
    /// has none — and none of those is something to put on screen.
    var curatedOutage: CuratedTrailOutage?

    init(listings: [CommunityListing], curatedOutage: CuratedTrailOutage? = nil) {
        self.listings = listings
        self.curatedOutage = curatedOutage
    }
}
