//
//  PhotoMatchAvailabilityTests.swift
//  OpenHikesTests
//
//  The photo section's caption asks whether the hike can be matched to
//  library photos on every body pass, and the passes it has are the ones a
//  photo write causes. The question walks the whole route — a timestamp scan,
//  and a revision hash once there are walks — so it is asked again only when
//  the route or the walks change, and every answer is still the real rule's:
//  a walk along a line the hike no longer has does not count.
//
//  Each test counts how often the real question is put, through
//  ``PhotoMatchAvailability``'s one seam, and checks the answer it gives.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Photo match availability")
struct PhotoMatchAvailabilityTests {
    /// How many unchanged body passes a test stands in for.
    private static let passes = 20

    private static var routeMeters: Double {
        RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute).totalDistanceMeters
    }

    /// An availability that asks the real question and counts each time it
    /// does.
    private final class Counted {
        private final class Tally {
            var count = 0
        }

        private let tally = Tally()
        let availability: PhotoMatchAvailability

        var asked: Int { tally.count }

        init() {
            availability = PhotoMatchAvailability { [tally] hike, route in
                tally.count += 1
                return hike.canMatchLibraryPhotos(along: route)
            }
        }
    }

    /// A walk over the first half of the fixture route, along the line
    /// `revision` names.
    private static func addWalk(
        to hike: Hike,
        in context: ModelContext,
        along revision: String? = PhotoDiscoveryFixture.routeRevision
    ) {
        let walk = PhotoDiscoveryFixture.walk(
            hikeID: hike.id,
            fromStep: 0,
            toStep: 9,
            covering: 0...(routeMeters / 2),
            routeDistanceMeters: routeMeters,
            routeRevision: revision
        )
        context.insert(walk)
        walk.hike = hike
    }

    /// The bug: an untimed route with one walk along it, read once per photo
    /// taken. Nothing the answer depends on moves, so it is worked out once.
    @Test("a photo write between reads asks nothing again")
    func unchangedReadsAskOnce() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)
        let counted = Counted()

        for _ in 0..<Self.passes {
            #expect(counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
            hike.photos.append(HikePhoto(pathExtension: "heic"))
        }

        #expect(counted.asked == 1)
    }

    /// A `@Model` filters no same-value write, so a save can hand the route
    /// back as a new array of the same points. The inputs compare by value.
    @Test("the same route written back asks nothing again")
    func sameRouteWrittenBackAsksNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)
        let counted = Counted()
        _ = counted.availability.canMatchLibraryPhotos(hike, along: hike.route)

        hike.replaceRoute(with: hike.route.map(\.self))

        #expect(counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
        #expect(counted.asked == 1)
    }

    /// The revision guard, through the kept answer: after *Edit Route* the
    /// only walk is along a line the hike no longer has, so the caption stops
    /// promising a scan.
    @Test("a route edit asks again, and the walk along the old line stops counting")
    func routeEditAsksAgain() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)
        let counted = Counted()
        #expect(counted.availability.canMatchLibraryPhotos(hike, along: hike.route))

        hike.replaceRoute(with: Array(hike.route.reversed()))

        #expect(!counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
        #expect(!counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
        #expect(counted.asked == 2)
    }

    /// The other input: an imported trail nobody has walked can promise
    /// nothing until a walk along it finishes.
    @Test("a finished walk asks again, and counts")
    func newWalkAsksAgain() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        let counted = Counted()
        #expect(!counted.availability.canMatchLibraryPhotos(hike, along: hike.route))

        Self.addWalk(to: hike, in: context)

        #expect(counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
        #expect(counted.availability.canMatchLibraryPhotos(hike, along: hike.route))
        #expect(counted.asked == 2)
    }
}
