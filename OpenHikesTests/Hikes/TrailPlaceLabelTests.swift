//
//  TrailPlaceLabelTests.swift
//  OpenHikesTests
//
//  What an unnamed place is called. In the app bundle rather than beside
//  `TrailPlaceTests` on the host, because the words are the app's — see
//  `TrailPlace+Label.swift`.
//

@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail place labels")
struct TrailPlaceLabelTests {
    private static func place(name: String = "", symbol: TrailPlaceSymbol? = nil) -> TrailPlace {
        TrailPlace(latitude: 47.60, longitude: 12.98, name: name, symbol: symbol)
    }

    /// Unnamed is the normal case — the plan issue measures four fifths of the
    /// viewpoints and waterfalls in an Alpine box carrying no name at all — so
    /// the fallback chain is the thing that makes a list of them readable.
    @Test("an unnamed place is called after what it is")
    func unnamedPlacesAreCalledAfterTheirSymbol() {
        #expect(Self.place(symbol: .water).displayName == "Water")
        #expect(Self.place().displayName == "Place")
        #expect(Self.place(name: "Kühroint", symbol: .shelter).displayName == "Kühroint")
    }
}
