//
//  TrailStopNameTests.swift
//  OpenHikesTests
//
//  Which of the several things MapKit says about a place is the one a row
//  reads.
//
//  The half of reverse geocoding that can be asserted without a network: an
//  `MKMapItem` has been constructible by hand since iOS 26
//  (`init(location:address:)`), so every shape a response takes can be handed
//  to ``TrailStopName`` directly. ``MapKitTrailStopNaming`` — the half that
//  talks to MapKit — is deliberately not exercised here and cannot be; that is
//  what the seam is for.
//
//  **The finding these tests exist to pin: `MKMapItem.name` is never empty.**
//  Assign `nil` to it and MapKit hands back a localized placeholder, so
//  "has a name" is not a question that can be asked of one. That is why there
//  are two functions here rather than one ordered list of fallbacks, and why
//  ``TrailStopName/here(_:at:)`` never reaches for a name at all.
//
//  The second finding: an answer can be about somewhere else. Where there is
//  no address near a spot MapKit answers with the postcode the spot is in,
//  placed at the postcode's middle, which named every pin in one forest the
//  same. The answers below that show it are MapKit's own, word for word and
//  to the coordinate, as they came back on 2026-10-20.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

/// Every test is iOS 26's: each answer here is an `MKMapItem` built by hand,
/// which only iOS 26 can do — and a suite cannot carry `@available` itself.
/// The answer below 26 is held to its rule by `TrailStopEarlierNameTests`.
@Suite("Trail stop names")
struct TrailStopNameTests {
    private static let somewhere = CLLocation(latitude: 47.6300, longitude: 12.86)
    @available(iOS 26.0, *) private static let address = MKAddress(
        fullAddress: "Könyves Kálmán körút 12-14, 1097 Budapest",
        shortAddress: "Könyves Kálmán körút 12-14"
    )

    @available(iOS 26.0, *)
    private static func item(name: String?, address: MKAddress?) -> MKMapItem {
        let item = MKMapItem(location: somewhere, address: address)
        item.name = name
        return item
    }

    /// The placeholder, pinned. If a future SDK ever makes `name` genuinely
    /// optional this goes red, which is the signal to simplify the two
    /// functions below back into one.
    @available(iOS 26.0, *)
    @Test("MapKit always has something to call an item, even when it has nothing")
    func nameIsNeverEmpty() {
        let bare = Self.item(name: nil, address: nil)
        #expect(bare.name?.isEmpty == false, "a nulled name comes back as a placeholder")
    }

    @available(iOS 26.0, *)
    @Test("nothing at all is no name, either way")
    func noItemIsNoName() {
        #expect(TrailStopName.chosen(nil) == nil)
        #expect(TrailStopName.here(nil, at: Self.somewhere.coordinate) == nil)
    }

    // MARK: - What the hiker picked

    /// A summit, a hut or a station comes back with a name, and the name is
    /// what a hiker recognises — it is also what they tapped.
    @available(iOS 26.0, *)
    @Test("a picked place is called what it is called")
    func aPickedPlaceKeepsItsName() {
        let item = Self.item(name: "Lurdy Ház", address: Self.address)
        #expect(TrailStopName.chosen(item) == "Lurdy Ház")
    }

    // MARK: - What is at a spot

    /// The half a search result cannot answer: a tap in the middle of a field.
    /// An address is what "here" means, which is the same answer Apple Maps
    /// gives a dropped pin.
    @available(iOS 26.0, *)
    @Test("a tapped spot is named by its address, never by its name")
    func aSpotIsItsAddress() {
        let item = Self.item(name: "Lurdy Ház", address: Self.address)
        #expect(TrailStopName.here(item, at: Self.somewhere.coordinate) == "Könyves Kálmán körút 12-14")
    }

    @available(iOS 26.0, *)
    @Test("and by the full address when there is no short one")
    func theFullAddressIsTheLastResort() {
        let cityOnly = MKAddress(fullAddress: "1097 Budapest", shortAddress: nil)
        let item = Self.item(name: nil, address: cityOnly)
        #expect(TrailStopName.here(item, at: Self.somewhere.coordinate) == "1097 Budapest")
    }

    /// The placeholder has nowhere to get in: an item MapKit could not place is
    /// no name at all, and the row keeps the word for what it is to the route.
    @available(iOS 26.0, *)
    @Test("a spot MapKit cannot place is no name, not a placeholder")
    func anUnplaceableSpotIsNoName() {
        let item = Self.item(name: nil, address: nil)
        #expect(TrailStopName.here(item, at: Self.somewhere.coordinate) == nil)
    }

    // MARK: - An answer about somewhere else

    /// A pin in the forest above the Traunsee, and what MapKit said about it:
    /// the postcode, placed 1.8 km away at the postcode's middle. Every pin in
    /// that forest got the same answer, which is how two rows of one route
    /// both came to read "4810 Gmunden".
    @available(iOS 26.0, *)
    @Test("a postcode answered from across the valley is no name for the spot")
    func aPostcodeIsNoName() {
        let pin = CLLocationCoordinate2D(latitude: 47.9118, longitude: 13.8215)
        let postcode = MKMapItem(
            location: CLLocation(latitude: 47.9195217, longitude: 13.8003063),
            address: MKAddress(fullAddress: "4810 Gmunden, Austria", shortAddress: "4810 Gmunden")
        )
        postcode.name = "4810"

        #expect(TrailStopName.here(postcode, at: pin) == nil)
        // Where the pin is, though, it truthfully says — which is what the
        // place sheet asks it.
        #expect(TrailStopName.address(of: postcode) == "4810 Gmunden, Austria")
    }

    /// A summit is named at its own mark, which a pin on the top need not be
    /// right on: this answer stood 552 m off, and is still the mountain the
    /// pin is on. Its short address is also MapKit's, gap and all.
    @available(iOS 26.0, *)
    @Test("a summit a few hundred metres off is still its name, without MapKit's empty part")
    func aSummitNamesItsTop() {
        let top = CLLocationCoordinate2D(latitude: 47.8727, longitude: 13.8306)
        let summit = MKMapItem(
            location: CLLocation(latitude: 47.8721271, longitude: 13.837932),
            address: MKAddress(
                fullAddress: "Traunstein, 4810 Gmunden, Austria",
                shortAddress: "Traunstein,, Gmunden"
            )
        )
        summit.name = "Traunstein"

        #expect(TrailStopName.here(summit, at: top) == "Traunstein, Gmunden")
    }

    @available(iOS 26.0, *)
    @Test("an answer is a name up to a kilometre from the spot, and not beyond")
    func theBoundIsAKilometer() throws {
        let bound = TrailStopName.farthestAnswerMeters
        let near = MKMapItem(location: Self.east(of: Self.somewhere, by: bound - 10), address: Self.address)
        let far = MKMapItem(location: Self.east(of: Self.somewhere, by: bound + 10), address: Self.address)
        try #require(near.location.distance(from: Self.somewhere) < bound)
        try #require(far.location.distance(from: Self.somewhere) > bound)

        #expect(TrailStopName.here(near, at: Self.somewhere.coordinate) != nil)
        #expect(TrailStopName.here(far, at: Self.somewhere.coordinate) == nil)
    }

    /// A spot about `meters` due east of `location` — near enough, which the
    /// test above checks rather than assumes.
    private static func east(of location: CLLocation, by meters: Double) -> CLLocation {
        let metersPerDegree = 111_320 * cos(location.coordinate.latitude * .pi / 180)
        return CLLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude + meters / metersPerDegree
        )
    }

    /// The bound every name in this app is taken through where it enters — and
    /// this one arrives from a service rather than from a keyboard, which is
    /// exactly the unattended input ``HikeTitle``'s argument is about.
    @available(iOS 26.0, *)
    @Test("a name arriving from MapKit is bounded like any other")
    func aLongNameIsBounded() throws {
        let long = String(repeating: "Kehlsteinhaus ", count: 100)
        let name = try #require(TrailStopName.chosen(Self.item(name: long, address: nil)))
        #expect(name.count < long.count)
        #expect(name.count <= TextBound.title.characters)
    }
}
