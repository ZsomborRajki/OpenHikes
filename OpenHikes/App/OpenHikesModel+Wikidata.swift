//
//  OpenHikesModel+Wikidata.swift
//  OpenHikes
//
//  Where the place cards ask Wikipedia, assembled at launch.
//

import Foundation

extension OpenHikesModel {
    /// The place cards' way to Wikidata, Wikipedia and Commons, or `nil` for
    /// a launch that must not ask — which draws every card as it was drawn
    /// before there was a section to draw.
    ///
    /// The guard ``makeTrailPhotoSource()`` makes, on its terms: Wikimedia's
    /// services are run for everybody on donations, and no suite may reach
    /// them. The one way past it is the scenario that seeds the places, so a
    /// launch whose search finds ``SeededTrailPointSource``'s summit finds
    /// what Wikipedia says about it too — see ``SeededWikidataPlaceSource``.
    static func makeWikidataLookup() -> WikidataPlaceLookup? {
        #if DEBUG
        if SeededTrailPointSource.Scenario(argument: AppLaunchEnvironment.trailPointScenarioName) == .seeded {
            return WikidataPlaceLookup(source: SeededWikidataPlaceSource())
        }
        #endif
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return WikidataPlaceLookup(source: WikidataPlaceSource())
    }
}
