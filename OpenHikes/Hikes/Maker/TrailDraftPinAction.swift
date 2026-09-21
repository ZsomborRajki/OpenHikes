//
//  TrailDraftPinAction.swift
//  OpenHikes
//
//  What a tap on the map offers to do with the spot it landed on.
//
//  ## Why a tap asks instead of acting
//
//  Phase 1 through 3 put a point down the instant the map was tapped, and a
//  tap on a leg cut that leg in two. That is the fastest way to draw and the
//  worst way to *plan*: a hiker looking at a valley taps a saddle to find out
//  what is there and has instead extended their trail to it, and the only way
//  back is an undo they have to know exists. A map is a thing people touch to
//  look at things.
//
//  So a tap drops a provisional pin and opens its callout, and the drawing
//  changes when a button in that callout is pressed. The tap is free, every
//  edit is deliberate, and the callout is where a place gets to say what it is
//  — which is the other half of this phase, and the reason *Mark a Place* is
//  in the same list as the route verbs rather than behind a mode of its own.
//
//  ## The verbs follow from how much line there is
//
//  With nothing drawn there is one thing a spot can be, and it is the start.
//  With one point down there is one thing it can be, and it is the other end.
//  Only from the third tap onwards is there a real choice — a stop along the
//  way, or a new far end — and that is the only point at which the hiker is
//  asked to make one. A callout that offered *Add Stop* to a hiker with no
//  trail would be offering to insert a point into a line that does not exist.
//
//  *Mark a Place* is offered at every count, including none: what is at a spot
//  does not depend on whether a route goes past it yet, and a hiker who marks
//  the hut before drawing anything has done the most useful thing first.
//
//  Its own type, and free of MapKit, because *which verbs a callout offers* is
//  a rule rather than a drawing — and the callout it is drawn in is a
//  `UIStackView` inside a `MKAnnotationView`, which is not a thing a suite can
//  interrogate. See ``MapView/Coordinator/applyTrailDraftPin(_:)`` for the
//  half that acts on one.
//

import Foundation

nonisolated enum TrailDraftPinAction: String, CaseIterable, Equatable, Sendable {
    // Alphabetical, because the linter wants them sorted. The order a hiker
    // sees is ``offered(forWaypointCount:)``'s, which is a decision and is
    // made there.
    //
    // The raw values are what ``accessibilityIdentifier`` is spelled from, so
    // they are stable names rather than sentences: a title is translated and
    // an identifier is not.
    /// A point in the middle: into the leg that was tapped, or into whichever
    /// leg runs nearest — see ``TrailDraft/nearestLegIndex(to:)``.
    case addStop = "add-stop"
    /// A new far end, past the one that is there.
    case makeDestination = "make-destination"
    /// Not part of the line at all. See ``TrailPlace``.
    case markAPlace = "mark-a-place"
    /// The far end of a trail that has exactly one point.
    case setAsDestination = "set-as-destination"
    /// The first point of a trail that has none.
    case startHere = "start-here"

    var title: String {
        switch self {
        case .startHere: String(localized: "Start Here")
        case .setAsDestination: String(localized: "Set as Destination")
        case .addStop: String(localized: "Add Stop")
        case .makeDestination: String(localized: "Make Destination")
        case .markAPlace: String(localized: "Mark a Place")
        }
    }

    var systemImageName: String {
        switch self {
        case .startHere: "flag"
        case .setAsDestination, .makeDestination: "flag.checkered"
        case .addStop: "arrow.trianglehead.branch"
        case .markAPlace: "mappin"
        }
    }

    /// Whether this verb changes the trail's line.
    ///
    /// The one that does not is ``markAPlace``, and the difference is load
    /// bearing rather than descriptive: a route verb asks OpenStreetMap for a
    /// leg and a place verb asks nothing, and the callout draws the two apart
    /// for the same reason — one of them is about where the walk goes.
    var changesTheLine: Bool { self != .markAPlace }

    /// The name a UI test finds this button by.
    ///
    /// Spelled from the raw value rather than from the title, because a title
    /// is translated and an identifier is not — and because a `Menu`'s contents
    /// already cost this feature one red run over an identifier that could not
    /// survive the system rebuilding the view. A callout accessory is an
    /// ordinary view this code owns, so an identifier on one does survive.
    var accessibilityIdentifier: String { "trail-draft-pin-\(rawValue)" }

    /// The verbs a callout offers over a trail that has `count` points.
    ///
    /// Ordered so that the verb which leaves the trail's two ends alone comes
    /// first. *Add Stop* changes the middle; *Make Destination* moves the far
    /// end, which is the larger edit and the one worth having to aim at.
    static func offered(forWaypointCount count: Int) -> [Self] {
        switch count {
        case 0: [.startHere, .markAPlace]
        case 1: [.setAsDestination, .markAPlace]
        default: [.addStop, .makeDestination, .markAPlace]
        }
    }
}
