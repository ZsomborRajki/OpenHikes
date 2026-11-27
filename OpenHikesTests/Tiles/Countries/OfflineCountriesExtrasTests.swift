//
//  OfflineCountriesExtrasTests.swift
//  OpenHikesTests
//
//  The offers a downloaded area's row makes once *Extra Detail* and
//  *Elevation Data* no longer describe it, by the owner's decision that a
//  switch changes nothing on the device: when there is one, what it names,
//  and what becomes of a download the hiker asked for on one. That a flip
//  itself brings and deletes nothing is each switch's own suite's
//  (`OfflineCountriesDetailTests`, `OfflineCountriesElevationSwitchTests`).
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: what a downloaded area offers to add or delete")
struct OfflineCountriesExtrasTests {
    private typealias Heights = OfflineCountriesElevationTests
    private typealias Role = OfflineCountryManifest.Role

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )
    private let detail = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 15, x: 17_704, y: 11_649): Data("z15".utf8)],
        maximumZoom: 15,
        minimumZoom: 15
    )
    private let elevation = Heights.elevation(Heights.level(295))

    private func slovenia(build: String = "20261117") -> OfflineCountryManifest.Country {
        OfflineCountryFixture.country(bytes: basemap, build: build, detail: detail, elevation: elevation)
    }

    private var everyFile: [Role: Data] { [.basemap: basemap, .detail: detail, .elevation: elevation] }

    /// Slovenia on the device with the files in `files`, as written there,
    /// and the model started over it with `offered` on the list.
    private func launch(
        in directory: URL,
        holding files: [Role: Data],
        offering offered: [OfflineCountryManifest.Country]
    ) async throws -> OfflineCountryHarness {
        let store = OfflineCountryStore(directory: directory)
        try store.prepare()
        let country = slovenia()
        for file in country.files {
            try files[file.role]?.write(to: store.fileURL(for: file))
        }
        try store.write(installed: [
            OfflineCountryStore.Record(
                country: country,
                installedAt: .now,
                hasDetail: files[.detail] != nil,
                hasElevation: files[.elevation] != nil
            ),
        ])
        return await OfflineCountryHarness.make(in: directory, offering: offered)
    }

    @Test("an area not on the device, or coming down for the first time, offers nothing")
    func nothingToOffer() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia()])
            #expect(harness.countries.addition(to: "SI") == nil)
            #expect(harness.countries.removal(from: "SI") == nil)
            harness.countries.extend("SI")
            harness.countries.trim("SI")
            #expect(harness.downloader.requests.isEmpty)

            harness.countries.setIncludesElevation(false)
            harness.countries.download(slovenia())
            harness.countries.setIncludesElevation(true)
            #expect(harness.countries.addition(to: "SI") == nil)
            #expect(harness.countries.removal(from: "SI") == nil)
            #expect(harness.downloader.requests.map(\.key.role) == [.basemap, .detail], "as the switches stood")
        }
    }

    @Test("an area down with everything the switches ask for offers nothing, and neither tap does anything")
    func matched() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(in: directory, holding: everyFile, offering: [slovenia()])

            #expect(harness.countries.addition(to: "SI") == nil)
            #expect(harness.countries.removal(from: "SI") == nil)
            harness.countries.extend("SI")
            harness.countries.trim("SI")
            #expect(harness.downloader.requests.isEmpty)
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .detail, .elevation])
        }
    }

    /// One switch each way: the area is offered what it lacks and, apart
    /// from that, to delete what it holds, and each tap does only its own.
    @Test("an area with zoom 15 and no heights, under the opposite switches, offers each, and each tap does its own")
    func oneEachWay() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(
                in: directory,
                holding: [.basemap: basemap, .detail: detail],
                offering: [slovenia()]
            )
            harness.countries.setIncludesDetail(false)

            #expect(harness.countries.addition(to: "SI")?.extras == .elevation)
            #expect(harness.countries.removal(from: "SI")?.extras == .detail)

            harness.countries.trim("SI")
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap])
            #expect(harness.downloader.requests.isEmpty, "deleting brings nothing")
            #expect(harness.countries.addition(to: "SI")?.extras == .elevation)

            harness.countries.extend("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.elevation])
        }
    }

    @Test("an area the list no longer holds offers nothing to add, and still to delete what a switch turned off")
    func goneFromTheList() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(in: directory, holding: [.basemap: basemap, .detail: detail], offering: [])

            #expect(harness.countries.addition(to: "SI") == nil, "its heights are on no server")
            harness.countries.setIncludesDetail(false)
            #expect(harness.countries.removal(from: "SI")?.byteCount == Int64(detail.count))
            harness.countries.trim("SI")
            #expect(harness.countries.installed["SI"]?.hasDetail == false)
        }
    }

    /// Mended first: its row says the download was damaged, and *Try Again*
    /// brings that file. What a switch turned off can still go, and a file
    /// that would not open goes with it, which leaves nothing to mend.
    @Test("an area with a file that will not open offers nothing to add, and deleting that file leaves nothing to mend")
    func fileThatWillNotOpen() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(
                in: directory,
                holding: [.basemap: basemap, .elevation: Data("not an archive".utf8)],
                offering: [slovenia()]
            )
            #expect(harness.countries.needsRepair("SI"))
            #expect(harness.countries.addition(to: "SI") == nil, "though it lacks its zoom 15")
            #expect(harness.countries.removal(from: "SI") == nil)
            #expect(harness.downloader.requests.isEmpty)

            harness.countries.setIncludesElevation(false)
            #expect(harness.countries.removal(from: "SI")?.extras == .elevation)
            harness.countries.trim("SI")

            #expect(!harness.countries.needsRepair("SI"))
            #expect(harness.countries.addition(to: "SI")?.extras == .detail)
        }
    }

    /// *Try Again* mends what the area holds, whatever the switches say
    /// now: the row said that file was damaged, not that it would go.
    @Test("mending an area brings the file that would not open, though its switch is off, and nothing it lacks")
    func mendingIgnoresTheSwitches() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(
                in: directory,
                holding: [.basemap: basemap, .elevation: Data("not an archive".utf8)],
                offering: [slovenia()]
            )
            harness.countries.setIncludesElevation(false)

            harness.countries.repair("SI")

            #expect(harness.downloader.requests.map(\.key.role) == [.elevation])
        }
    }

    // MARK: - A download the hiker asked for on an offer

    @Test("trying a failed addition again asks for the same files, and no more than the switches still ask for")
    func retryingAnAddition() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(in: directory, holding: [.basemap: basemap], offering: [slovenia()])
            harness.countries.extend("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.detail, .elevation])
            harness.downloader.fail(.detail, resumeData: nil)
            harness.downloader.fail(.elevation, resumeData: nil)

            await harness.countries.retry("SI")
            #expect(harness.downloader.requests.dropFirst(2).map(\.key.role) == [.detail, .elevation])
            harness.downloader.fail(.detail, resumeData: nil)
            harness.downloader.fail(.elevation, resumeData: nil)

            harness.countries.setIncludesDetail(false)
            await harness.countries.retry("SI")
            #expect(harness.downloader.requests.dropFirst(4).map(\.key.role) == [.elevation])
            #expect(harness.countries.downloads["SI"]?.files.map(\.role) == [.elevation])
        }
    }

    /// Without this the row stayed failed for good: nothing was left for
    /// *Try Again* to ask for, and it asked for nothing.
    @Test("trying a failed addition again once its switch is off ends it, and leaves the area as it was")
    func retryingWhatIsNoLongerAskedFor() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(
                in: directory,
                holding: [.basemap: basemap, .detail: detail],
                offering: [slovenia()]
            )
            harness.countries.extend("SI")
            harness.downloader.fail(.elevation, resumeData: nil)
            #expect(harness.countries.downloads["SI"]?.hasFailed == true)

            harness.countries.setIncludesElevation(false)
            await harness.countries.retry("SI")

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.store.pending().isEmpty)
            #expect(harness.downloader.requests.map(\.key.role) == [.elevation], "nothing more was asked for")
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .detail])
        }
    }

    /// The server deletes a build it has moved past, so the addition can
    /// never finish. The new build is the hiker's to start, at its size.
    @Test("trying a failed addition again once the server has a newer build ends it, and starts no update unasked")
    func retryingPastABuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = try await launch(in: directory, holding: [.basemap: basemap], offering: [slovenia()])
            harness.countries.extend("SI")
            harness.downloader.fail(.detail, resumeData: nil)
            let asked = harness.downloader.requests.count
            let newer = slovenia(build: "20261201")
            harness.server.serve(OfflineCountryFixture.manifest([newer]))

            await harness.countries.retry("SI")

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.downloader.requests.count == asked)
            #expect(harness.countries.update(for: "SI") == newer)
            #expect(harness.countries.addition(to: "SI") == nil)
        }
    }
}
