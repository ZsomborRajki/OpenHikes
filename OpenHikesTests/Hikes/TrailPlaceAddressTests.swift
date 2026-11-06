//
//  TrailPlaceAddressTests.swift
//  OpenHikesTests
//
//  What the maker's place card is told about an address it has stopped
//  asking for, which is nothing (#1351).
//
//  The card keeps its state as the hiker taps one spot after another, and
//  its `.task(id:)` is keyed by the coordinate. SwiftUI cancels the question
//  about the last spot and asks about the new one at once, without waiting,
//  so the last spot's answer — or the `nil` a refused question comes back as
//  — can land after the new one's, and stays, because the newer task has
//  finished.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

/// Every test is iOS 26's, for the stub's answers, which are `MKMapItem`s
/// built by hand — and a suite cannot carry `@available` itself.
@MainActor
@Suite("Trail place address after cancellation", .timeLimit(.minutes(1)))
struct TrailPlaceAddressTests {
    /// A geocoder that answers from memory, holding the question about one
    /// spot, once it has been asked, until its gate opens.
    private final class HeldNaming: TrailStopNaming {
        let gate = TestGate()
        private let held: Double
        private let addresses: [Double: String]

        init(addresses: [Double: String], holding held: Double) {
            self.addresses = addresses
            self.held = held
        }

        func mapItem(at coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
            if coordinate.latitude == held { await gate.wait() }
            guard #available(iOS 26.0, *), let address = addresses[coordinate.latitude] else { return nil }
            return MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: MKAddress(fullAddress: address, shortAddress: address)
            )
        }
    }

    /// Everything the card was handed, in order.
    private final class Shown {
        private(set) var answers: [String?] = []

        func record(_ answer: String?) { answers.append(answer) }
    }

    private enum Lakeside {
        static let longitude: Double = 13.80
        static let south: Double = 47.90
        static let north: Double = 47.92
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Lakeside.longitude)
    }

    /// The first spot's question held in MapKit, a second tap answered
    /// first, and then the first let go. The second spot's address is what
    /// stays, and the first question hands over nothing at all.
    @available(iOS 26.0, *)
    @Test("an address found for a spot the card has moved on from is not shown")
    func anAddressForASpotTheCardLeftIsNotShown() async {
        let naming = HeldNaming(
            addresses: [
                Lakeside.south: "Esplanade 1, 4810 Gmunden",
                Lakeside.north: "Traunsteinstraße 2, 4810 Gmunden",
            ],
            holding: Lakeside.south
        )
        defer { naming.gate.open() }
        let maker = TrailDraftController(naming: naming)
        let shown = Shown()

        let replaced = Task { await maker.address(at: Self.coordinate(Lakeside.south)) { shown.record($0) } }
        await settleDelegateHop(until: "the first spot's question to be under way") { naming.gate.isHolding }
        // What `.task(id:)` does when the card is handed another spot:
        // cancel, and ask the next without waiting for the last.
        replaced.cancel()
        await maker.address(at: Self.coordinate(Lakeside.north)) { shown.record($0) }
        naming.gate.open()
        await replaced.value

        #expect(shown.answers == ["Traunsteinstraße 2, 4810 Gmunden"])
    }
}
