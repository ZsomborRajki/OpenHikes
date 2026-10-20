//
//  CommunityUITests+PreviewChart.swift
//  OpenHikesUITests
//
//  A stranger's elevation chart, read on the map behind it.
//
//  A hike of the hiker's own has always moved a dot along its line as its
//  chart is scrubbed. A published hike's preview draws the same chart over a
//  map drawing that very route, and a finger dragged to the middle of it moved
//  nothing on the map at all — see `MapCommunityPreviewHighlight.swift`.
//
//  Driven end to end, because the wiring is the part that was missing: the
//  browser and the map each had everything they needed, and the chart's scrub
//  simply never reached them. `CommunityBrowserPreviewHighlightTests` and
//  `MapCoordinatorTests+CommunityPreviewHighlight.swift` pin the two halves;
//  this is the only place the preview screen is in the loop.
//

import XCTest

extension CommunityUITests {
    /// The dot stands where the chart's marker does — at the trailhead when
    /// the preview opens — and a tap in the middle of the chart moves it
    /// somewhere else on the map.
    ///
    /// A tap rather than a drag, for the reason
    /// `OpenHikesUITests+ElevationChart.swift` gives: its synthesised touch is
    /// briefer than any human one, so a chart that answers it answers a drag.
    @MainActor
    func testScrubbingAPreviewsChartMovesItsDotOnTheMap() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(
            scrollUntilVisible(chart, in: app),
            "precondition: a published hike's preview draws its elevation chart"
        )
        let dot = element("community-preview-highlight", in: app)
        XCTAssertTrue(
            dot.waitForExistence(timeout: UITestTimeout.existence),
            "the chart's marker stands at the trailhead, and so should its dot on the map"
        )
        let atTrailhead = dot.frame

        chart.coordinate(withNormalizedOffset: CGVector(dx: Self.middleOfTheChart, dy: 0.5)).tap()

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { dot.exists && dot.frame != atTrailhead },
            "the middle of the chart is somewhere else along the line, and the dot should go there"
        )
    }

    private static let middleOfTheChart = 0.5
}
