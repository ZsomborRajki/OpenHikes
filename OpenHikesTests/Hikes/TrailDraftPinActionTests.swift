//
//  TrailDraftPinActionTests.swift
//  OpenHikesTests
//
//  Which verbs a dropped pin's callout offers.
//
//  The list is a rule about how much line there is, and it is invisible from
//  everywhere: the callout is a `UIStackView` inside an `MKAnnotationView`, so
//  a suite that tried to read it would be reading MapKit. Pinned here instead,
//  where the rule lives.
//
//  **What pressing one does is asserted next door**, in
//  `MapCoordinatorTests+TrailDraft`, against the real
//  ``MapView/Coordinator/applyTrailDraftPin(_:at:legIndex:in:)`` and a real
//  `MKMapView`. Restating that method here would be a mirror with no compiler
//  behind it, which is a thing this repository has already paid for once.
//

@testable import OpenHikes
import Testing

@Suite("Trail draft pin actions")
struct TrailDraftPinActionTests {
    /// With nothing drawn there is one thing a spot can be, and with one point
    /// down there is one thing it can be. Only from the third tap is there a
    /// choice to make, and only then is the hiker asked to make one.
    @Test("the route verbs follow from how much line there is")
    func theVerbsFollowTheLine() {
        #expect(TrailDraftPinAction.offered(forWaypointCount: 0) == [.startHere, .markAPlace])
        #expect(TrailDraftPinAction.offered(forWaypointCount: 1) == [.setAsDestination, .markAPlace])
        #expect(
            TrailDraftPinAction.offered(forWaypointCount: 2)
                == [.addStop, .makeDestination, .markAPlace]
        )
        #expect(
            TrailDraftPinAction.offered(forWaypointCount: 9)
                == [.addStop, .makeDestination, .markAPlace]
        )
    }

    /// What is at a spot does not depend on whether a route goes past it yet,
    /// so this one is offered at every count — including none.
    @Test("marking a place is always offered")
    func markingIsAlwaysOffered() {
        for count in 0...4 {
            #expect(TrailDraftPinAction.offered(forWaypointCount: count).contains(.markAPlace))
        }
    }

    /// The split the callout draws with, and the one the routing depends on: a
    /// route verb asks OpenStreetMap for a leg and a place verb asks nothing.
    @Test("marking a place is the one verb that does not change the line")
    func onlyMarkingLeavesTheLineAlone() {
        for action in TrailDraftPinAction.allCases {
            #expect(action.changesTheLine == (action != .markAPlace))
        }
    }

    /// Every verb has to be findable by the suite that presses buttons, and an
    /// identifier that collided would send that suite to the wrong one.
    @Test("every verb carries its own identifier and its own words")
    func everyVerbIsDistinct() {
        let identifiers = TrailDraftPinAction.allCases.map(\.accessibilityIdentifier)
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.hasPrefix("trail-draft-pin-") })
        let titles = TrailDraftPinAction.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }
}
