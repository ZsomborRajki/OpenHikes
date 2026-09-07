//
//  WeatherSubject.swift
//  OpenHikes
//
//  What the weather badge is *about*.
//
//  The badge used to be about wherever the phone was, derived from the fix
//  stream and nothing else, which made it a reading nobody had asked for: a
//  walker who searched Budapest and zoomed the map there still saw the
//  temperature outside their own window, and a walker who opened an imported
//  trail saw the same. The forecast a person wants is the forecast for the
//  place they are looking at, and "the place they are looking at" is a thing
//  the app already knows at three specific moments — it just never wrote it
//  down.
//
//  So this is the written-down version. ``WeatherFocus`` holds one subject at
//  a time and three call sites set it:
//
//  - the recorder, when a recording becomes active (`OpenHikesView`)
//  - hike selection, when a route is drawn and the map fits to it
//  - search, when `MKLocalSearch` resolves and the map zooms to a region
//
//  Everything downstream — when to spend a WeatherKit request, what the badge
//  draws, what its VoiceOver value says — is a function of the subject rather
//  than of the sensor. See ``WeatherRequestState`` for the first and
//  ``WeatherBadge`` for the others.
//

import CoreLocation
import Foundation

/// The place the badge's reading belongs to.
///
/// Carries a name for everything except ``me``, because a temperature for
/// somewhere other than here is misleading without one. The badge draws that
/// name; `nil` is what tells it to draw the "here" glyph instead.
nonisolated enum WeatherSubject: Equatable, Sendable {
    /// Wherever the walker is. Owned by the recorder while a recording is
    /// active, and left in place afterwards so stopping a recording doesn't
    /// blank the badge.
    case me(CLLocationCoordinate2D)
    /// A resolved search result.
    case place(CLLocationCoordinate2D, name: String)
    /// A selected hike's route. The coordinate starts at the route's anchor
    /// and follows the walker once they are actually in its area — see
    /// ``WeatherFocus/walkerMoved(to:)``.
    case trail(CLLocationCoordinate2D, hikeID: UUID, name: String)

    /// The subject a selected route implies, or `nil` for a hike with no
    /// geometry to be about.
    ///
    /// The anchor is the route's midpoint rather than its start: a walker who
    /// has opened a trail is asking about the trail, and on a long one the
    /// trailhead can be a different valley from the middle of it.
    static func trail(
        id: UUID,
        name: String,
        along coordinates: [CLLocationCoordinate2D]
    ) -> Self? {
        guard !coordinates.isEmpty else { return nil }
        return .trail(coordinates[coordinates.count / 2], hikeID: id, name: name)
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .me(let coordinate): coordinate
        case .place(let coordinate, _): coordinate
        case .trail(let coordinate, _, _): coordinate
        }
    }

    /// What the badge writes beside the temperature, or `nil` for a reading
    /// that is simply "here".
    var placeName: String? {
        switch self {
        case .me: nil
        case .place(_, let name): name
        case .trail(_, _, let name): name
        }
    }

    /// The identity ``WeatherRequestState`` keys its freshness and backoff on.
    ///
    /// Deliberately independent of the coordinate: `me` is one subject whose
    /// position changes, not a new subject every time the walker moves, and a
    /// trail re-selected after a detour is the same trail. This is what
    /// replaced the old ~1.1 km lat/lon grid, whose keys changed underneath a
    /// stationary walker often enough to need an eight-bucket LRU to absorb
    /// the oscillation.
    var key: String {
        switch self {
        case .me: "me"
        case .place(_, let name): "place:\(name)"
        case .trail(_, let hikeID, _): "trail:\(hikeID.uuidString)"
        }
    }

    /// The same subject moved to `coordinate`, keeping its identity.
    func moved(to coordinate: CLLocationCoordinate2D) -> Self {
        switch self {
        case .me: .me(coordinate)
        case .place(_, let name): .place(coordinate, name: name)
        case let .trail(_, hikeID, name): .trail(coordinate, hikeID: hikeID, name: name)
        }
    }

    /// `CLLocationCoordinate2D` is not `Equatable`, so this spells the
    /// comparison out rather than leaving the compiler to synthesize one it
    /// cannot.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.me(lhs), .me(rhs)):
            lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
        case let (.place(lhs, lhsName), .place(rhs, rhsName)):
            lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude && lhsName == rhsName
        case let (.trail(lhs, lhsID, lhsName), .trail(rhs, rhsID, rhsName)):
            lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
                && lhsID == rhsID && lhsName == rhsName
        default:
            false
        }
    }
}

/// Which subject the badge is currently about, and who is allowed to change it.
///
/// The precedence is one rule: **an active recording owns the subject.** While
/// it does, a search or a hike selection changes the map and leaves the badge
/// alone, because a walker glancing at a badge mid-hike is asking about the
/// weather they are standing in and nothing else should be able to answer that
/// question for them. Everywhere else, the most recent explicit focus wins.
///
/// Stopping a recording releases the pin but keeps the subject. Clearing it
/// would blank the badge at the exact moment a walker is most likely to look
/// at it, and "here" remains a perfectly good answer once the recording has
/// ended.
@Observable
final class WeatherFocus {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// How near a trail's anchor a walker has to be for the subject to follow
    /// them along it rather than stay pinned to where the route starts.
    ///
    /// A region test, not a route match: this asks "are they out on this
    /// trail's hillside", and a walker anywhere inside this radius shares the
    /// trail's weather closely enough that either coordinate would give the
    /// same forecast — moving to theirs is simply the more honest of two
    /// equivalent answers. Getting it wrong in the other direction is what
    /// matters, and 25 km is far outside anywhere a person could be while
    /// browsing a trail in another country.
    ///
    /// Deliberately not the route geometry. Matching a fix against the
    /// polyline is a real question with a real answer — ``TrailWalkSession``
    /// asks it — but it is the wrong question here, and asking it would put
    /// route matching underneath the weather badge.
    static let trailFollowRadius: CLLocationDistance = 25_000

    private(set) var subject: WeatherSubject?

    /// True while a recording owns ``subject``. Search and selection are
    /// no-ops until it clears.
    private(set) var isPinnedToWalker = false

    init(subject: WeatherSubject? = nil) {
        self.subject = subject
    }

    /// A recording became active: the badge is about the walker from here
    /// until it ends.
    func pinToWalker(at coordinate: CLLocationCoordinate2D) {
        isPinnedToWalker = true
        setSubject(.me(coordinate))
    }

    /// The recording ended. The pin lifts; the subject stays where it is.
    func unpinFromWalker() {
        isPinnedToWalker = false
    }

    /// An explicit focus from search or hike selection.
    ///
    /// Ignored outright while a recording holds the pin — see the type's own
    /// note on precedence.
    func focus(on subject: WeatherSubject) {
        guard !isPinnedToWalker else { return }
        setSubject(subject)
    }

    /// Makes the walker the subject when nothing else has claimed it.
    ///
    /// The honest default: with no recording running, no trail selected and no
    /// search resolved, the place the badge is about is here. Without this a
    /// launch that restores no selection has no subject at all, and the badge
    /// would sit on whatever was persisted from the last session — getting
    /// older — until the user happened to do one of the three things that sets
    /// a subject explicitly.
    func defaultToWalker(at coordinate: CLLocationCoordinate2D) {
        guard subject == nil else { return }
        setSubject(.me(coordinate))
    }

    /// A new position for the walker, from significant-change delivery.
    ///
    /// Moves the subject only when the subject is about the walker: `me`
    /// always, a `trail` when they are inside ``trailFollowRadius`` of it, and
    /// a searched `place` never — someone reading Budapest's forecast from
    /// Vienna does not want it to become Vienna's because they walked to the
    /// shops.
    func walkerMoved(to coordinate: CLLocationCoordinate2D) {
        guard let subject else { return }
        switch subject {
        case .me:
            setSubject(.me(coordinate))
        case .trail(let anchor, _, _):
            guard Self.distance(from: anchor, to: coordinate) <= Self.trailFollowRadius else { return }
            setSubject(subject.moved(to: coordinate))
        case .place:
            return
        }
    }

    /// The subject as an async sequence, for the poll loop to wake on.
    ///
    /// Same shape as ``LocationManager/fixes``, and for the same reason: the
    /// loop should wake when the answer changes rather than ask on a timer.
    var subjects: Observations<WeatherSubject?, Never> {
        Observations { self.subject }
    }

    /// Assigns only on a real change, so a repeated fix or a re-selection of
    /// the hike already showing doesn't wake the poll loop to conclude it has
    /// nothing to do.
    private func setSubject(_ next: WeatherSubject) {
        guard subject != next else { return }
        subject = next
    }

    private static func distance(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(
                from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            )
    }
}
