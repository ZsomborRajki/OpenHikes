//
//  SharedStoreBasemapTests.swift
//  OpenHikesSharedTests
//
//  The basemap half of the App Group contract: a manifest per trail and their
//  images in a directory beside them, with nothing but the code below keeping
//  the two in step.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared store basemaps")
struct SharedStoreBasemapTests {
    /// The manifest carries the hike it was rendered for, and the read side
    /// checks it. Without that check a set that outlived the snapshot it was
    /// rendered alongside would be drawn under a different trail — the right
    /// picture of the wrong walk.
    @Test("a set rendered for another hike is refused rather than drawn")
    func setForAnotherHikeIsRefused() throws {
        try withSharedStoreSandbox { _ in
            let set = SharedStoreSandbox.basemapSet()
            SharedStore.saveBasemapSet(set)

            #expect(SharedStore.loadBasemapSet(for: set.hikeID) != nil)
            #expect(SharedStore.loadBasemapSet(for: UUID()) == nil)
        }
    }

    @Test("a manifest whose images are all on disk is trusted")
    func completeManifestIsTrusted() throws {
        try withSharedStoreSandbox { _ in
            let set = SharedStoreSandbox.basemapSet(fileNames: ["a.png", "b.png"])
            for image in set.images {
                SharedStore.writeBasemapImage(Data("png".utf8), named: image.fileName)
            }

            #expect(SharedStore.hasAllBasemapImages(in: set))
        }
    }

    /// The check the producing side makes before deciding its work is already
    /// done. A manifest that outlived its images has to be re-rendered, not
    /// believed — which is exactly the state a prune or a container wipe
    /// leaves behind.
    @Test("a manifest that outlived one of its images is not trusted")
    func manifestMissingAnImageIsNotTrusted() throws {
        try withSharedStoreSandbox { _ in
            let set = SharedStoreSandbox.basemapSet(fileNames: ["a.png", "b.png"])
            SharedStore.writeBasemapImage(Data("png".utf8), named: "a.png")

            #expect(SharedStore.hasAllBasemapImages(in: set) == false)
        }
    }

    /// `allSatisfy` on an empty collection is `true`, so without the explicit
    /// emptiness guard an empty manifest would report as complete and a render
    /// that produced nothing would never be retried.
    @Test("a manifest advertising no images at all is not trusted")
    func emptyManifestIsNotTrusted() throws {
        try withSharedStoreSandbox { _ in
            #expect(SharedStore.hasAllBasemapImages(in: SharedStoreSandbox.basemapSet(fileNames: [])) == false)
        }
    }

    /// The images directory does not exist in a fresh container, and nothing
    /// creates it up front — the first write does, which is why the write
    /// reports whether it landed rather than assuming it did.
    @Test("the first image write creates the directory it needs")
    func firstWriteCreatesTheDirectory() throws {
        try withSharedStoreSandbox { root in
            let directory = root.appendingPathComponent(
                SharedStoreSandbox.basemapDirectoryName,
                isDirectory: true
            )
            try #require(!FileManager.default.fileExists(atPath: directory.path))

            #expect(SharedStore.writeBasemapImage(Data("png".utf8), named: "a.png"))
            #expect(SharedStore.basemapImageData(named: "a.png") == Data("png".utf8))
        }
    }

    /// Pruning enumerates the directories, so it has to cope with there not
    /// being any — the ordinary state after ``SharedStore/clearBasemaps()``.
    @Test("pruning directories that were never created does nothing")
    func pruningWithoutADirectoryIsHarmless() throws {
        try withSharedStoreSandbox { _ in
            SharedStore.pruneBasemaps(keeping: [UUID()])
            SharedStore.pruneBasemapImages(supersededBy: SharedStoreSandbox.basemapSet())
            SharedStore.clearBasemaps(for: UUID())
            SharedStore.removeBasemapImages(named: ["a.png"])
            #expect(SharedStore.basemapImageData(named: "a.png") == nil)
        }
    }

    // MARK: One set per trail

    /// The bug this layout exists for: a widget pinned to one trail drew its
    /// line on a grey fill as soon as another trail was selected, because the
    /// selection's set was written over the only manifest there was.
    @Test("saving one trail's set leaves another trail's set in place")
    func setsForTwoTrailsCoexist() throws {
        try withSharedStoreSandbox { _ in
            let pinned = SharedStoreSandbox.basemapSet()
            let selected = SharedStoreSandbox.basemapSet()
            SharedStore.saveBasemapSet(pinned)
            SharedStore.saveBasemapSet(selected)

            #expect(SharedStore.loadBasemapSet(for: pinned.hikeID) == pinned)
            #expect(SharedStore.loadBasemapSet(for: selected.hikeID) == selected)
        }
    }

    /// What bounds the container: every trail not kept loses its manifest and
    /// its images, including a stray image named for no trail at all — the
    /// shape an abandoned write leaves.
    @Test("pruning keeps the named trails' sets and takes everything else")
    func pruningKeepsByTrail() throws {
        try withSharedStoreSandbox { _ in
            let kept = Self.publishedSet()
            let dropped = Self.publishedSet()
            SharedStore.writeBasemapImage(Data("png".utf8), named: "stray.png")

            SharedStore.pruneBasemaps(keeping: [kept.hikeID])

            #expect(SharedStore.loadBasemapSet(for: kept.hikeID) == kept)
            #expect(SharedStore.hasAllBasemapImages(in: kept))
            #expect(SharedStore.loadBasemapSet(for: dropped.hikeID) == nil)
            #expect(SharedStore.basemapImageData(named: dropped.images[0].fileName) == nil)
            #expect(SharedStore.basemapImageData(named: "stray.png") == nil)
        }
    }

    /// A deleted hike's map, and nobody else's.
    @Test("clearing one trail's basemaps leaves the others")
    func clearingOneTrailSparesTheOthers() throws {
        try withSharedStoreSandbox { _ in
            let deleted = Self.publishedSet()
            let other = Self.publishedSet()

            SharedStore.clearBasemaps(for: deleted.hikeID)

            #expect(SharedStore.loadBasemapSet(for: deleted.hikeID) == nil)
            #expect(SharedStore.basemapImageData(named: deleted.images[0].fileName) == nil)
            #expect(SharedStore.loadBasemapSet(for: other.hikeID) == other)
            #expect(SharedStore.hasAllBasemapImages(in: other))
        }
    }

    /// A manifest with its one image on disk, named the way the renderer
    /// names images — after the trail — since that is what the prunes read.
    private static func publishedSet() -> TrailBasemapSet {
        let hikeID = UUID()
        let set = SharedStoreSandbox.basemapSet(
            hikeID: hikeID,
            fileNames: ["\(hikeID.uuidString)-square-light.jpg"]
        )
        SharedStore.saveBasemapSet(set)
        SharedStore.writeBasemapImage(Data("png".utf8), named: set.images[0].fileName)
        return set
    }
}
