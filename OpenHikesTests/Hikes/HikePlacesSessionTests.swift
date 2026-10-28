//
//  HikePlacesSessionTests.swift
//  OpenHikesTests
//
//  A route's place-search state survives replacing either host, including the
//  two possible appear/disappear orders. Actual source calls and cancellation
//  are counted; all answers come from injected, continuation-controlled sources.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Place search destination sessions", .timeLimit(.minutes(1)))
struct HikePlacesSessionTests {
    private static let here = CLLocationCoordinate2D(latitude: 47.605, longitude: 12.98)
    private static let line = [
        RouteCoordinate(latitude: 47.60, longitude: 12.98),
        RouteCoordinate(latitude: 47.61, longitude: 12.98),
    ]
    private static let spring = TrailPlace(coordinate: here, name: "Spring", symbol: .water)
    private static let far = TrailPlace(latitude: 47.605, longitude: 13.02, name: "Far hut", symbol: .shelter)

    private static func owner(in context: ModelContext, nearby: Bool = false)
        -> (SheetPresentation, SheetRoute, HikePlacesSession) {
        let hike = Fixture.hike(in: context, route: line)
        let route = nearby ? SheetRoute.placesNearby(hike) : .placesAround(hike)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike), route]
        return (presentation, route, presentation.placeSearch(for: route))
    }

    private static func attach(_ session: HikePlacesSession, to around: TrailPlacesAround)
        throws -> (host: UUID, token: Int) {
        let host = UUID()
        let token = try #require(session.attach(host: host, to: around, handlers: handlers))
        return (host, token)
    }

    private static var handlers: TrailPlacesAround.Handlers {
        .init(
            select: { _ in /* no selection in this fixture */ },
            searchArea: { /* searches are invoked explicitly */ },
            dropPin: { _ in /* no pin drops in this fixture */ }
        )
    }

    @Test("a pending corridor request and all choices survive either host ordering", arguments: [true, false])
    func corridorSurvivesRotation(oldDisappearsFirst: Bool) async throws {
        let context = try Fixture.modelContext()
        let (presentation, route, session) = Self.owner(in: context)
        let around = TrailPlacesAround()
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let first = try Self.attach(session, to: around)
        await session.search.receiveArea([Self.far], along: Self.line).value
        session.search.reach = .nearby
        session.search.selection = Self.far.id
        let request = try #require(session.searchAlongIfNeeded(Self.line, from: source, showing: [.water, .shelter]))
        await source.waitUntilAsked()

        presentation.layout = .sidePanel
        if oldDisappearsFirst { session.detach(host: first.host, token: first.token) }
        let second = try Self.attach(session, to: around)
        if !oldDisappearsFirst { session.detach(host: first.host, token: first.token) }
        #expect(session.searchAlongIfNeeded(Self.line, from: source, showing: [.water, .shelter]) == nil)
        await source.release()
        await request.value

        #expect(presentation.placeSearch(for: route) === session)
        #expect(session.search.selection == Self.far.id)
        #expect(session.search.reach == .nearby)
        #expect(session.search.askedAbout == [Self.far.id])
        #expect(session.search.candidates(showing: [.water, .shelter], held: []).map(\.id).contains(Self.far.id))
        #expect(await source.calls == 1)
        #expect(await source.cancelledCalls == 0)
        #expect(around.isActive)
        presentation.layout = .bottomSheet
        session.detach(host: second.host, token: second.token)
        _ = try Self.attach(session, to: around)
        #expect(session.searchAlongIfNeeded(Self.line, from: source, showing: [.water, .shelter]) == nil)
        #expect(await source.calls == 1, "a completed request is reused too")
    }

    @Test("an outgoing host's dismissal cannot clear its replacement's card")
    func staleDismissalDoesNotCloseTheCard() throws {
        let context = try Fixture.modelContext()
        let (presentation, _, session) = Self.owner(in: context)
        let around = TrailPlacesAround()
        let first = try Self.attach(session, to: around)
        session.search.selection = Self.spring.id
        let outgoing = session.cardBinding(for: first.host)
        #expect(outgoing.wrappedValue)

        presentation.layout = .sidePanel
        outgoing.wrappedValue = false
        #expect(session.search.selection == Self.spring.id, "the layout revokes the old host before teardown")
        session.detach(host: first.host, token: first.token)
        let second = try Self.attach(session, to: around)
        outgoing.wrappedValue = false
        #expect(session.search.selection == Self.spring.id, "a late dismissal cannot close the new host")
        session.cardBinding(for: second.host).wrappedValue = false
        #expect(session.search.selection == nil, "the current host can still close its card")
    }

    @Test("Nearby retains its origin, last searched area, results and card without reframing or asking")
    func completedNearbySearchIsReused() async throws {
        let context = try Fixture.modelContext()
        let (presentation, route, session) = Self.owner(in: context, nearby: true)
        let source = HeldPlaceSearchSource(answer: [Self.spring], holding: false)
        let finder = TrailPointFinder(source: source)
        let around = TrailPlacesAround(finder: finder)
        let first = try Self.attach(session, to: around)
        let reads = FrameReads()
        Self.receiveNearby(session, using: finder)
        Self.askFirst(session, using: finder, reads: reads)
        await settleDelegateHop(until: "Nearby's first answer is merged") { !session.search.found.isEmpty }
        let area = CommunitySearchArea(coordinate: Self.here, radiusMeters: 750)
        session.askNearby(area, using: finder, avoiding: [])
        await source.waitUntilAnswered(2)
        await settleDelegateHop(until: "Nearby's second area is answered") { !finder.isSearching }
        session.search.selection = Self.spring.id
        let asked = session.asked

        presentation.layout = .sidePanel
        session.detach(host: first.host, token: first.token)
        _ = try Self.attach(session, to: around)
        Self.askFirst(session, using: finder, reads: reads)

        #expect(presentation.placeSearch(for: route) === session)
        #expect(session.asked == asked)
        #expect(session.asked.area == area)
        #expect(session.search.askedAbout == [Self.spring.id])
        #expect(session.search.selection == Self.spring.id)
        #expect(Self.here.latitude.isApproximatelyEqual(to: session.origin?.latitude ?? 0, absoluteTolerance: 0.000001))
        #expect(reads.positions == 1 && reads.lines == 1 && reads.frames == 1)
        #expect(await source.calls == 2, "neither completed area is asked for again")
    }

    @Test("Nearby keeps its pending area across either rotation order", arguments: [true, false])
    func nearbyRequestSurvivesRotation(oldDisappearsFirst: Bool) async throws {
        let context = try Fixture.modelContext()
        let (presentation, _, session) = Self.owner(in: context, nearby: true)
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let finder = TrailPointFinder(source: source)
        let around = TrailPlacesAround(finder: finder)
        let first = try Self.attach(session, to: around)
        let reads = FrameReads()
        Self.receiveNearby(session, using: finder)
        Self.askFirst(session, using: finder, reads: reads)
        await source.waitUntilAsked()
        let asked = session.asked

        presentation.layout = .sidePanel
        if oldDisappearsFirst { session.detach(host: first.host, token: first.token) }
        _ = try Self.attach(session, to: around)
        if !oldDisappearsFirst { session.detach(host: first.host, token: first.token) }
        Self.askFirst(session, using: finder, reads: reads)
        #expect(finder.isSearching)
        #expect(session.asked == asked)
        await source.release()
        await settleDelegateHop(until: "the retained Nearby request is merged") { !session.search.found.isEmpty }

        #expect(await source.calls == 1)
        #expect(await source.cancelledCalls == 0)
        #expect(session.asked.interrupted == nil)
        #expect(reads.frames == 1 && reads.positions == 1)
    }

    @Test("covering Nearby releases its map claim and retries only an interrupted area")
    func interruptedNearbyRequestIsRetried() async throws {
        let context = try Fixture.modelContext()
        let (presentation, route, session) = Self.owner(in: context, nearby: true)
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let finder = TrailPointFinder(source: source)
        let around = TrailPlacesAround(finder: finder)
        let first = try Self.attach(session, to: around)
        let reads = FrameReads()
        Self.receiveNearby(session, using: finder)
        Self.askFirst(session, using: finder, reads: reads)
        await source.waitUntilAsked()
        let area = session.asked.area
        session.detach(host: first.host, token: first.token)
        #expect(!around.isActive && !finder.isSearching)
        #expect(presentation.placeSearch(for: route) === session)

        let second = try Self.attach(session, to: around)
        Self.receiveNearby(session, using: finder)
        Self.askFirst(session, using: finder, reads: reads)
        await source.waitUntilAsked(2)
        await source.release()
        await source.waitUntilAnswered(2)
        await settleDelegateHop(until: "the retried Nearby request is merged") { !session.search.found.isEmpty }

        #expect(await source.calls == 2)
        #expect(await source.cancelledCalls == 1)
        #expect(session.asked.area == area && session.asked.interrupted == nil)
        #expect(reads.frames == 1 && reads.positions == 1)
        session.detach(host: second.host, token: second.token)
        _ = try Self.attach(session, to: around)
        Self.receiveNearby(session, using: finder)
        Self.askFirst(session, using: finder, reads: reads)
        #expect(!finder.isSearching, "an answered area is retained when returning from a covered screen")
        #expect(await source.calls == 2)
    }

    @Test("popping either place-search route cancels its request and retires its state", arguments: [false, true])
    func routePopCancelsAndReleasesItsState(nearby: Bool) async throws {
        let context = try Fixture.modelContext()
        let (presentation, route, session) = Self.owner(in: context, nearby: nearby)
        let source = HeldPlaceSearchSource(answer: [Self.spring])
        let finder = TrailPointFinder(source: source)
        let around = TrailPlacesAround(finder: finder)
        let host = try Self.attach(session, to: around)
        let request: Task<Void, Never>?
        if nearby {
            Self.receiveNearby(session, using: finder)
            Self.askFirst(session, using: finder, reads: FrameReads())
            request = nil
        } else {
            let started = try #require(session.searchAlongIfNeeded(Self.line, from: source, showing: [.water]))
            request = started
        }
        await source.waitUntilAsked()
        session.search.selection = Self.spring.id

        presentation.path.removeLast()
        await source.release()
        await request?.value
        await source.waitUntilAnswered()
        #expect(await source.cancelledCalls == 1)
        #expect(!around.isActive && !finder.isSearching)
        #expect(session.search.found.isEmpty && session.search.selection == nil)
        #expect(session.searchAlongIfNeeded(Self.line, from: source, showing: [.water]) == nil)
        #expect(session.receiveNearby([Self.spring], using: finder, avoiding: []) == nil)
        #expect(session.attach(host: host.host, to: around, handlers: Self.handlers) == nil)
        presentation.path.append(route)
        let fresh = presentation.placeSearch(for: route)
        #expect(fresh !== session)
        #expect(fresh.origin == nil && !fresh.asked.hasAsked)
        #expect(fresh.search.found.isEmpty && fresh.search.reach == .around)
    }

    @Test("releasing a place-search claim lets go of the finder's old destination callback")
    func poppedDestinationIsNotRetainedByTheFinder() throws {
        let context = try Fixture.modelContext()
        let finder = TrailPointFinder()
        let around = TrailPlacesAround(finder: finder)
        weak var released: HikePlacesSession?
        do {
            let (presentation, _, session) = Self.owner(in: context, nearby: true)
            released = session
            _ = try Self.attach(session, to: around)
            finder.onFound { places in
                session.receiveNearby(places, using: finder, avoiding: [])
            }
            presentation.path.removeLast()
        }
        #expect(released == nil)
    }

    private final class FrameReads {
        var positions = 0
        var lines = 0
        var frames = 0
    }

    private static func askFirst(_ session: HikePlacesSession, using finder: TrailPointFinder, reads: FrameReads) {
        session.askNearbyFirst(
            using: finder,
            avoiding: [],
            line: {
                reads.lines += 1
                return Self.line.map(\.clCoordinate)
            },
            position: {
                reads.positions += 1
                return here
            },
            show: { _ in reads.frames += 1 }
        )
    }

    private static func receiveNearby(_ session: HikePlacesSession, using finder: TrailPointFinder) {
        finder.onFound { [weak session, weak finder] places in
            guard let session, let finder else { return }
            session.receiveNearby(places, using: finder, avoiding: [])
        }
    }
}
