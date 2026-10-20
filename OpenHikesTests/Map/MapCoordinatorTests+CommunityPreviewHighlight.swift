//
//  MapCoordinatorTests+CommunityPreviewHighlight.swift
//  OpenHikesTests
//
//  What the map does with an open preview's chart position: the dot a hike
//  of the hiker's own has always had, standing on a stranger's line.
//
//  `CommunityBrowserPreviewHighlightTests` pins when there is a dot. These pin
//  what MapKit is given for one: that it reaches the map at all — which is
//  the report this exists for, a finger in the middle of the chart and
//  nothing moving on the map — that a drag moves one annotation rather than
//  churning them, that it is drawn in the colour of the line it stands on
//  rather than in the hiker's route tint, and that it is not the hike's own
//  dot.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftUI
import Testing

extension MapCoordinatorTests {
    private enum PreviewDot {
        static let latitude: Double = 47.62
        static let longitude: Double = 12.86
        /// How far north each point of the route is from the last.
        static let step: Double = 0.01
        /// The previewed hike's route, which the map draws at full strength
        /// and the dot stands on.
        static let route = (0..<3).map { index in
            RouteCoordinate(latitude: latitude + Double(index) * step, longitude: longitude)
        }
        /// Two points along it, as the chart would hand them over: half way
        /// along its first stretch, and half way along its second.
        static let partWay = CLLocationCoordinate2D(latitude: latitude + step / 2, longitude: longitude)
        static let further = CLLocationCoordinate2D(latitude: latitude + step + step / 2, longitude: longitude)
        static let tolerance = 1e-9
    }

    /// A browser with `listing`'s preview open and its route loaded — the
    /// state its chart can be scrubbed in.
    private func previewing(_ listing: CommunityListing) -> CommunityBrowser {
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        browser.previewOpened(listing)
        browser.previewLoaded(PreviewDot.route, of: listing)
        return browser
    }

    /// The report this file exists for: a finger on the middle of a
    /// stranger's chart, and nothing on the map moving.
    @Test("scrubbing a preview's chart puts a dot on its line")
    func aPreviewScrubPutsADotOnTheMap() async throws {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }

        browser.previewScrubbed(to: PreviewDot.partWay, of: listing)
        await settle(until: "the preview's dot to reach the map") {
            coordinator.communityPreviewHighlight != nil
        }

        let dot = try #require(coordinator.communityPreviewHighlight)
        #expect(map.annotations.contains { $0 === dot })
        #expect(dot.coordinate.latitude.isApproximatelyEqual(
            to: PreviewDot.partWay.latitude,
            absoluteTolerance: PreviewDot.tolerance
        ))
        #expect(
            coordinator.highlightAnnotation == nil,
            "the hiker's own dot belongs to their selected route, not to this one"
        )
    }

    /// A drag reports at display rate. Adding and removing the annotation per
    /// sample would churn MapKit's views sixty times a second — the reason
    /// the hike's own dot is moved in place, and this one is too.
    @Test("scrubbing a preview's chart moves one dot rather than replacing it")
    func aPreviewScrubMovesTheDotInPlace() async throws {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        browser.previewScrubbed(to: PreviewDot.partWay, of: listing)
        await settle(until: "the preview's dot to reach the map") {
            coordinator.communityPreviewHighlight != nil
        }
        let dot = try #require(coordinator.communityPreviewHighlight)

        browser.previewScrubbed(to: PreviewDot.further, of: listing)
        await settle(until: "the dot to follow the chart") {
            dot.coordinate.latitude.isApproximatelyEqual(
                to: PreviewDot.further.latitude,
                absoluteTolerance: PreviewDot.tolerance
            )
        }

        #expect(coordinator.communityPreviewHighlight === dot, "the same dot, moved")
        #expect(map.annotations.filter { $0 is CommunityPreviewHighlightAnnotation }.count == 1)
    }

    /// The dot is the hike's own, drawn in the colour of the line it stands
    /// on — the listing's, which the chart is drawn in too — and never in the
    /// route tint, which belongs to the hiker's selected hike and is red here
    /// so the two cannot be mistaken for each other.
    ///
    /// And in front of every pin: it starts at the trailhead, where a
    /// published hike's own marker stands, and the default z-order leaves
    /// MapKit free to draw it underneath.
    @Test("a preview's dot is drawn in its line's colour, in front of the pins")
    func aPreviewDotWearsTheListingsColour() async throws {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        coordinator.routeTint = .red

        browser.previewScrubbed(to: PreviewDot.partWay, of: listing)
        await settle(until: "the preview's dot to reach the map") {
            coordinator.communityPreviewHighlight != nil
        }
        let dot = try #require(coordinator.communityPreviewHighlight)

        let view = try #require(coordinator.mapView(map, viewFor: dot))
        #expect(view.canShowCallout == false)
        #expect(view.zPriority == .max)
        #if canImport(UIKit)
        #expect(view.layer.backgroundColor == UIColor(listing.tint).withAlphaComponent(1).cgColor)
        #expect(view.layer.backgroundColor != UIColor(Color.red).withAlphaComponent(1).cgColor)
        #endif
    }

    /// Backing out of the preview takes its line off the map, and the dot
    /// with it.
    @Test("closing the preview takes its dot off the map")
    func closingThePreviewRemovesItsDot() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        browser.previewScrubbed(to: PreviewDot.partWay, of: listing)
        await settle(until: "the preview's dot to reach the map") {
            coordinator.communityPreviewHighlight != nil
        }

        browser.previewClosed(listing)
        await settle(until: "the dot to leave with its preview") {
            coordinator.communityPreviewHighlight == nil
        }

        #expect(!map.annotations.contains { $0 is CommunityPreviewHighlightAnnotation })
    }

    /// Two answers for two different hikes can reach the map in one pass —
    /// observation coalesces what lands between two hops. Moving the first
    /// hike's dot there would carry its colour onto the second hike's line,
    /// so a dot for another listing is a new dot.
    @Test("a dot for another hike replaces the last one rather than moving it")
    func aDotForAnotherHikeIsANewDot() throws {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        coordinator.applyCommunityPreviewHighlight((first, PreviewDot.partWay), on: map)
        let firstDot = try #require(coordinator.communityPreviewHighlight)
        coordinator.applyCommunityPreviewHighlight((second, PreviewDot.further), on: map)
        let secondDot = try #require(coordinator.communityPreviewHighlight)

        #expect(secondDot !== firstDot)
        #expect(secondDot.listingID == "summit")
        #expect(secondDot.tint == second.tint)
        #expect(!map.annotations.contains { $0 === firstDot })
        #expect(map.annotations.filter { $0 is CommunityPreviewHighlightAnnotation }.count == 1)
    }
}
