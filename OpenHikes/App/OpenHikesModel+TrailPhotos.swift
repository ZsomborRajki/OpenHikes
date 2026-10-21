//
//  OpenHikesModel+TrailPhotos.swift
//  OpenHikes
//
//  The trail maker and community map's photo source, and the maker's copy
//  into a saved hike, assembled at launch.
//

import Foundation

extension OpenHikesModel {
    static func makeTrailPhotoCopy() -> TrailDraftPhotoCopy {
        #if DEBUG
        if AppLaunchEnvironment.refusesTrailPhotoCopy {
            return TrailDraftPhotoCopy(save: { _ in throw CocoaError(.fileWriteUnknown) })
        }
        #endif
        return TrailDraftPhotoCopy()
    }

    /// Where the maker's *Search this area* asks for photographs, or `nil`
    /// for a launch that must not ask.
    ///
    /// The guard ``makeTrailPointSource()`` makes, on its terms:
    /// Wikimedia's API is run for everybody on donations, and a suite that
    /// fell into it would be spending its patience on a stub's worth of
    /// pictures. The one way past it is the same scenario name, so a launch
    /// that seeds the places seeds the photographs with them — see
    /// ``SeededCommonsPhotoSource``. `--ui-test-community=commons` is the
    /// other: it seeds Commons for the curated preview, and the *Community*
    /// tab's *Search this area* asks through this source too.
    ///
    /// Also the *Community* tab's — see ``makeCommunityBrowser(transport:blocks:maker:)``.
    static func makeTrailPhotoSource() -> (any CommonsPhotoSourcing)? {
        #if DEBUG
        if SeededTrailPointSource.Scenario(argument: AppLaunchEnvironment.trailPointScenarioName) == .seeded
            || SeededCommunityTransport.Scenario(argument: AppLaunchEnvironment.communityScenarioName) == .commons {
            return SeededCommonsPhotoSource()
        }
        #endif
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return makeLiveCommonsSource()
    }

    /// Wikimedia Commons, with what it said about each file kept in `Caches`
    /// for every launch that asks it — see ``CommonsPhotoStore``.
    static func makeLiveCommonsSource() -> WikimediaCommonsSource {
        WikimediaCommonsSource(store: CommonsPhotoStore.defaultDirectory().map { CommonsPhotoStore(directory: $0) })
    }
}
