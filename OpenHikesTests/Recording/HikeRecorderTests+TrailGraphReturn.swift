//
//  HikeRecorderTests+TrailGraphReturn.swift
//  OpenHikesTests
//
//  A region the recording has loaded is not loaded for good. The trail-graph
//  provider keeps a bounded number of regions and lets go of the least
//  recently used, so one the hiker left behind can be gone by the time they
//  are back in it. A recorder that took `.loaded` as permanent would never ask
//  for it again, and would match the walk home against nothing.
//
//  The stub keeps every region, so what these pin is the asking: arriving in a
//  loaded region asks again, and walking on inside one does not.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension HikeRecorderTests {

    @Test("coming back to a loaded region asks for it again, and walking on in it does not")
    func returningToALoadedRegionAsksAgain() async throws {
        let provider = StubTrailGraphProvider(graph: .empty)
        let recorder = makeRecorder(
            trailGraphProvider: provider,
            trailGraphNetworkDecision: Self.denyingSpeculativeFetches
        )
        await recorder.start()
        let home = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let away = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.96)
        let homeRegion = try #require(provider.region(containing: home))
        let awayRegion = try #require(provider.region(containing: away))

        deliverFix(at: home)
        await waitUntilLoaded(homeRegion, recorder: recorder)
        // Far enough to be another region, slow enough that
        // ``RecordingFixPolicy`` accepts the walk there and back.
        clock.advance(by: 4000)
        deliverFix(at: away)
        await waitUntilLoaded(awayRegion, recorder: recorder)
        clock.advance(by: 4000)
        deliverFix(at: home)
        await waitUntilLoaded(homeRegion, recorder: recorder)

        #expect(await provider.prefetches() == [homeRegion, awayRegion, homeRegion])

        clock.advance(by: 60)
        deliverFix(at: CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.86))
        // Nothing to wait for: the fix was accepted, and the region its
        // predecessor was already in refused, while it was on the stack.
        #expect(recorder.stats.pointCount == 4)
        #expect(recorder.trailGraphPrefetchStates[homeRegion] == .loaded)
    }

    /// A pause is time the hiker can spend browsing other hikes, each of which
    /// reads regions of its own, so the one they stopped in is not safe either.
    @Test("the first fix after a resume asks again for the region it lands in")
    func resumingAsksAgainForTheRegion() async throws {
        let provider = StubTrailGraphProvider(graph: .empty)
        let recorder = makeRecorder(
            trailGraphProvider: provider,
            trailGraphNetworkDecision: Self.denyingSpeculativeFetches
        )
        await recorder.start()
        let spot = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let region = try #require(provider.region(containing: spot))

        deliverFix(at: spot)
        await waitUntilLoaded(region, recorder: recorder)
        recorder.pause()
        clock.advance(by: 300)
        await recorder.resume()
        deliverFix(at: spot)
        await waitUntilLoaded(region, recorder: recorder)

        #expect(await provider.prefetches() == [region, region])
    }

    // MARK: Harness

    /// Keeps the provider's log to the regions the hiker is in: the sweep of
    /// the eight around each is speculative, and would otherwise ask for the
    /// home region on arriving next door.
    private static let denyingSpeculativeFetches: @Sendable (TileFetchPurpose) -> TileNetworkDecision = { purpose in
        purpose == .speculative ? .denied("cellular-speculative") : .allowed
    }

    private func deliverFix(at coordinate: CLLocationCoordinate2D) {
        source.deliver(fix(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    /// `.loaded` is written once the provider's prefetch has returned, so it
    /// follows the log entry this suite reads. A region being asked again is
    /// `.fetching` from the moment its fix is delivered until then.
    private func waitUntilLoaded(
        _ region: TrailGraphRegion,
        recorder: HikeRecorder,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await settleDelegateHop(
            until: "the trail-graph prefetch for \(region) to land",
            sourceLocation: sourceLocation
        ) {
            recorder.trailGraphPrefetchStates[region] == .loaded
        }
    }
}
