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
//  ``TrailStopName/here(_:)`` never reaches for a name at all.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Trail stop names")
struct TrailStopNameTests {
    private static let somewhere = CLLocation(latitude: 47.6300, longitude: 12.86)
    private static let address = MKAddress(
        fullAddress: "Könyves Kálmán körút 12-14, 1097 Budapest",
        shortAddress: "Könyves Kálmán körút 12-14"
    )

    private static func item(name: String?, address: MKAddress?) -> MKMapItem {
        let item = MKMapItem(location: somewhere, address: address)
        item.name = name
        return item
    }

    /// The placeholder, pinned. If a future SDK ever makes `name` genuinely
    /// optional this goes red, which is the signal to simplify the two
    /// functions below back into one.
    @Test("MapKit always has something to call an item, even when it has nothing")
    func nameIsNeverEmpty() {
        let bare = Self.item(name: nil, address: nil)
        #expect(bare.name?.isEmpty == false, "a nulled name comes back as a placeholder")
    }

    @Test("nothing at all is no name, either way")
    func noItemIsNoName() {
        #expect(TrailStopName.chosen(nil) == nil)
        #expect(TrailStopName.here(nil) == nil)
    }

    // MARK: - What the hiker picked

    /// A summit, a hut or a station comes back with a name, and the name is
    /// what a hiker recognises — it is also what they tapped.
    @Test("a picked place is called what it is called")
    func aPickedPlaceKeepsItsName() {
        let item = Self.item(name: "Lurdy Ház", address: Self.address)
        #expect(TrailStopName.chosen(item) == "Lurdy Ház")
    }

    // MARK: - What is at a spot

    /// The half a search result cannot answer: a tap in the middle of a field.
    /// An address is what "here" means, which is the same answer Apple Maps
    /// gives a dropped pin.
    @Test("a tapped spot is named by its address, never by its name")
    func aSpotIsItsAddress() {
        let item = Self.item(name: "Lurdy Ház", address: Self.address)
        #expect(TrailStopName.here(item) == "Könyves Kálmán körút 12-14")
    }

    @Test("and by the full address when there is no short one")
    func theFullAddressIsTheLastResort() {
        let cityOnly = MKAddress(fullAddress: "1097 Budapest", shortAddress: nil)
        #expect(TrailStopName.here(Self.item(name: nil, address: cityOnly)) == "1097 Budapest")
    }

    /// The placeholder has nowhere to get in: an item MapKit could not place is
    /// no name at all, and the row keeps the word for what it is to the route.
    @Test("a spot MapKit cannot place is no name, not a placeholder")
    func anUnplaceableSpotIsNoName() {
        #expect(TrailStopName.here(Self.item(name: nil, address: nil)) == nil)
    }

    /// The bound every name in this app is taken through where it enters — and
    /// this one arrives from a service rather than from a keyboard, which is
    /// exactly the unattended input ``HikeTitle``'s argument is about.
    @Test("a name arriving from MapKit is bounded like any other")
    func aLongNameIsBounded() throws {
        let long = String(repeating: "Kehlsteinhaus ", count: 100)
        let name = try #require(TrailStopName.chosen(Self.item(name: long, address: nil)))
        #expect(name.count < long.count)
        #expect(name.count <= TextBound.title.characters)
    }
}
