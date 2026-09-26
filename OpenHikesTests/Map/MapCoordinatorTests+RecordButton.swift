//
//  MapCoordinatorTests+RecordButton.swift
//  OpenHikesTests
//
//  The record button, which moved out of the sheet and into the maker's pill
//  on the map's leading edge.
//
//  Three things are worth pinning and none is visible from the sheet. It is
//  the *lower* of the two, so it is the one nearest a thumb and the credit
//  line; a tap on it raises the request the view tree answers rather than
//  doing anything to the map; and it turns red with a recording under way
//  without anything re-rendering, including on a map built mid-recording.
//

import Foundation
import MapKit
import Observation
@testable import OpenHikes
import OpenHikesShared
import RealModule
import Testing

/// Stands in for ``HikeRecorder/isActive``: something observable a test can
/// flip by hand, read through the closure ``RecordingEntry`` takes.
@Observable
final class RecordingStateStub {
    var isLive = false
}

extension MapCoordinatorTests {
    #if os(iOS)
    /// The pill's two buttons by their identifiers, in the map's coordinates.
    private func pillButton(_ identifier: String, in pill: UIView) -> UIView? {
        var pending: [UIView] = [pill]
        while let view = pending.popLast() {
            if view.accessibilityIdentifier == identifier { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    #endif

    @Test("the record button sits under the maker's, nearest the credit line")
    func recordButtonIsTheLowerOfTheTwo() throws {
        #if os(iOS)
        trailMaker.setHostScreenPresent(false)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)
        let credit = try #require(coordinator.attributionView)
        map.setNeedsLayout()
        map.layoutIfNeeded()

        let maker = try #require(pillButton("map-trail-maker-button", in: pill))
        let record = try #require(pillButton("record-hike-button", in: pill))
        let makerFrame = maker.convert(maker.bounds, to: map)
        let recordFrame = record.convert(record.bounds, to: map)

        #expect(recordFrame.minY > makerFrame.maxY, "record is not below the maker")
        #expect(
            recordFrame.minX.isApproximatelyEqual(to: makerFrame.minX, absoluteTolerance: 1),
            "the two are not one column"
        )
        // The bottom of the pill is the record button, and the gap under it is
        // the one the slot gives every pill.
        #expect(
            pill.convert(pill.bounds, to: map).maxY.isApproximatelyEqual(to: recordFrame.maxY, absoluteTolerance: 1)
        )
        #expect(
            (credit.frame.minY - recordFrame.maxY).isApproximatelyEqual(
                to: MapView.creditLineSpacing,
                absoluteTolerance: 1
            )
        )
        #endif
    }

    /// The map cannot reach the sheet's navigation stack, so a tap ends as a
    /// request the view tree answers — the one a widget tap leaves.
    @Test("a tap on the record button asks for the recording screen")
    func recordButtonRaisesTheRequest() async throws {
        #if os(iOS)
        trailMaker.setHostScreenPresent(false)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)
        let record = try #require(pill.recordButton)

        record.sendActions(for: .primaryActionTriggered)

        await settle(until: "the request to arrive") { openRequests.request == 1 }
        #expect(openRequests.link == TrailWidgetDeepLink.recordingURL())
        #expect(trailMaker.openRequest == 0, "the tap reached the maker as well")
        #endif
    }

    @Test("the record button turns red while a recording is live, and back")
    func recordButtonFollowsTheRecording() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)
        let record = try #require(pill.recordButton)
        #expect(!pill.isRecording)
        #expect(record.accessibilityLabel == "Record a hike")

        recordingState.isLive = true
        await settle(until: "the button to show the live recording") { pill.isRecording }
        #expect(record.accessibilityLabel == "Open hike recording")

        recordingState.isLive = false
        await settle(until: "the button to go back to rest") { !pill.isRecording }
        #expect(record.accessibilityLabel == "Record a hike")
        #endif
    }

    /// A rotation rebuilds the map, and nothing about the recording changes to
    /// prompt a second pass — so the first one has to get it right.
    @Test("a map built mid-recording draws the button red at once")
    func recordButtonRedOnFirstBuild() throws {
        #if os(iOS)
        recordingState.isLive = true
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)

        #expect(pill.isRecording)
        #endif
    }
}
