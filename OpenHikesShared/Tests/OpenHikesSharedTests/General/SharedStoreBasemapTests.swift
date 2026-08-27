//
//  SharedStoreBasemapTests.swift
//  OpenHikesSharedTests
//
//  The basemap half of the App Group contract: a manifest in one file and its
//  images in a directory beside it, with nothing but the code below keeping
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

    /// Pruning enumerates the directory, so it has to cope with there not
    /// being one — the ordinary state after ``SharedStore/clear()``.
    @Test("pruning an images directory that was never created does nothing")
    func pruningWithoutADirectoryIsHarmless() throws {
        try withSharedStoreSandbox { _ in
            SharedStore.pruneBasemapImages(keeping: ["a.png"])
            SharedStore.removeBasemapImages(named: ["a.png"])
            #expect(SharedStore.basemapImageData(named: "a.png") == nil)
        }
    }
}
