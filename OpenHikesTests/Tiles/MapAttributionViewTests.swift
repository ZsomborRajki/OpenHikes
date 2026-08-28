//
//  MapAttributionViewTests.swift
//  OpenHikesTests
//
//  The credit line drawn on the map. Every provider here requires the credit
//  to be present *and* linked, so what is asserted is exactly that: the words
//  the provider's terms ask for, and a tap that reaches the licence.
//
//  A UIKit view rather than a SwiftUI one, so this drives it directly instead
//  of through the map — see ``MapAttributionView`` for why it is a subview.
//

import Foundation
@testable import OpenHikes
import Testing
#if canImport(UIKit)
import UIKit

@Suite("Map attribution")
struct MapAttributionViewTests {
    /// Collects what a tap would have opened, so no test reaches Safari.
    private final class OpenedLinks {
        private(set) var urls: [URL] = []

        func record(_ url: URL) { urls.append(url) }
    }

    private func makeView() -> (view: MapAttributionView, opened: OpenedLinks) {
        let opened = OpenedLinks()
        let view = MapAttributionView { url in opened.record(url) }
        return (view, opened)
    }

    private func button(in view: MapAttributionView) -> UIButton? {
        view.subviews.compactMap { $0 as? UIButton }.first
    }

    private func label(in view: MapAttributionView) -> UILabel? {
        view.subviews
            .flatMap(\.subviews)
            .flatMap(\.subviews)
            .compactMap { $0 as? UILabel }
            .first
    }

    @Test("a raster provider's credits are shown compactly and spoken in full")
    func showsEveryCredit() {
        let (view, _) = makeView()
        let attribution = TileProvider.thunderforestOutdoors.attribution
        view.update(with: attribution)

        #expect(!view.isHidden)
        #expect(label(in: view)?.text == attribution.compactText)
        #expect(button(in: view)?.accessibilityLabel == attribution.plainText)
        // Thunderforest requires both parties named, "Maps ©" and "Data ©".
        #expect(attribution.plainText.contains("Thunderforest"))
        #expect(attribution.plainText.contains("OpenStreetMap contributors"))
    }

    /// The map is the space-constrained placement, so it drops the decoration
    /// — and nothing else. Every party a provider's terms require stays named,
    /// which is the half of this that is a licensing obligation rather than a
    /// layout preference.
    @Test(
        "the compact line names every required party",
        arguments: [
            (TileProvider.openStreetMap, "© OpenStreetMap"),
            (TileProvider.stadiaOutdoors, "© Stadia Maps, OpenMapTiles, OpenStreetMap"),
            (TileProvider.thunderforestOutdoors, "© Thunderforest, OpenStreetMap"),
        ]
    )
    func compactLineKeepsEveryParty(provider: TileProvider, expected: String) {
        let (view, _) = makeView()
        view.update(with: provider.attribution)

        #expect(label(in: view)?.text == expected)
        #expect(expected.count <= provider.attribution.plainText.count)
        // A shortened credit still has to reach every licence it names.
        #expect(
            provider.attribution.credits.allSatisfy { credit in
                expected.contains(credit.compactTitle) && credit.url != nil
            }
        )
    }

    /// MapKit draws its own **Legal** link over the system base map, and
    /// reproducing it would credit Apple twice and link neither.
    @Test("the system base map draws no credit of ours")
    func hidesWhenMapKitCredits() {
        let (view, _) = makeView()
        view.update(with: TileProvider.appleMaps.attribution)
        #expect(view.isHidden)
    }

    @Test("no source at all draws nothing")
    func hidesWithoutASource() {
        let (view, _) = makeView()
        // Before anything has been applied at all: a view that started visible
        // would draw an empty pill over the map on the frames before a source
        // resolves, and `update(with:)` would return early rather than fix it.
        #expect(view.isHidden)

        view.update(with: TileProvider.openStreetMap.attribution)
        #expect(!view.isHidden)

        view.update(with: nil)
        #expect(view.isHidden)
    }

    /// One credit is one destination, so the tap goes straight there rather
    /// than through a menu of one.
    @Test("a single credit opens its licence directly")
    func singleCreditOpensDirectly() {
        let (view, opened) = makeView()
        view.update(with: TileProvider.openStreetMap.attribution)

        let target = button(in: view)
        #expect(target?.menu == nil)
        #expect(target?.showsMenuAsPrimaryAction == false)

        target?.sendActions(for: .primaryActionTriggered)
        #expect(opened.urls == [TileAttribution.Credit.openStreetMap.url].compactMap(\.self))
    }

    /// Three parties cannot share one destination, so they become a menu —
    /// with every one of them reachable, which is what "working links" means.
    @Test("every credit of a multi-party source is reachable")
    func multipleCreditsBecomeAMenu() {
        let (view, _) = makeView()
        let attribution = TileProvider.stadiaOutdoors.attribution
        view.update(with: attribution)

        let target = button(in: view)
        #expect(target?.showsMenuAsPrimaryAction == true)
        let titles = target?.menu?.children.map(\.title) ?? []
        #expect(titles == attribution.credits.map(\.title))
    }

    /// Rebuilt on a change and left alone otherwise: `update(with:)` is reached
    /// from every tile-source pass, and none of those may rewrite the line.
    @Test("re-applying the same credits changes nothing")
    func repeatedUpdatesAreIdempotent() {
        let (view, _) = makeView()
        let attribution = TileProvider.stadiaOutdoors.attribution
        view.update(with: attribution)
        let first = view.subviews.first
        view.update(with: attribution)
        #expect(view.subviews.first === first)
        #expect(label(in: view)?.text == attribution.compactText)
    }
}
#endif
