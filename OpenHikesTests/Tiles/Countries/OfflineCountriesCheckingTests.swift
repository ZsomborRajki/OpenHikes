//
//  OfflineCountriesCheckingTests.swift
//  OpenHikesTests
//
//  A download's files are checked one at a time, each a wait of seconds,
//  and the hiker can cancel the try meanwhile and download the same build
//  again, which stages its files at the same paths. A check that resumes for
//  the try that was cancelled has no say over those files: finding its own
//  copy broken, it must not delete the new try's (#1597).
//

import Foundation
@testable import OpenHikes
import Testing

/// Passes every check, except the next one once armed, which waits until
/// it is told how it went.
@MainActor
private final class HeldCheck {
    private var held: CheckedContinuation<Bool, Never>?
    private var holdsNext = false

    var isHolding: Bool { held != nil }

    func holdTheNext() {
        holdsNext = true
    }

    func check(_: OfflineCountryManifest.File, at _: URL) async -> Bool {
        guard holdsNext else { return true }
        holdsNext = false
        return await withCheckedContinuation { held = $0 }
    }

    func answer(_ isWhole: Bool) {
        held?.resume(returning: isWhole)
        held = nil
    }
}

@MainActor
@Suite("Offline countries: checking a try")
struct OfflineCountriesCheckingTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )
    private let check = HeldCheck()

    private func harness(in directory: URL, offering offered: [OfflineCountryManifest.Country]) async
        -> OfflineCountryHarness {
        await OfflineCountryHarness.make(in: directory, offering: offered) { [check] file, url in
            await check.check(file, at: url)
        }
    }

    /// Downloads `country` again while the cancelled try's check is out,
    /// lands its basemap at the same path, then has the old check find its
    /// copy broken and lands the rest. Waits for the new try to settle.
    private func replaceWhileChecking(
        _ country: OfflineCountryManifest.Country,
        in harness: OfflineCountryHarness
    ) async throws {
        harness.countries.download(country)
        try harness.downloader.land(.basemap, as: basemap)
        let basemapFile = try #require(country.files.first { $0.role == .basemap })
        try #require(FileManager.default.fileExists(atPath: harness.store.stagedURL(for: basemapFile).path))

        check.answer(false)
        try harness.downloader.land(.extras, as: extras)
        await settleDelegateHop(until: "the new try is installed, or has failed") {
            harness.countries.isInstalled("SI") || harness.countries.downloads["SI"]?.hasFailed == true
        }
    }

    @Test("a check that resumes for a cancelled try leaves the next try's staged file alone")
    func aCancelledTrysCheck() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await harness(in: directory, offering: [country])
            check.holdTheNext()
            harness.countries.download(country)
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the first try's check is out") { check.isHolding }

            harness.countries.cancel("SI")
            try await replaceWhileChecking(country, in: harness)

            #expect(harness.countries.isInstalled("SI"), "the new try kept its basemap, and installed")
            #expect(harness.store.installed().map(\.country) == [country])
        }
    }

    /// The shape the issue reports: the area deleted while its update is
    /// checked, and the same build downloaded again.
    @Test("an area deleted while its update is checked, and downloaded again, installs")
    func deletedWhileItsUpdateIsChecked() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261117", extras: extras)
            let harness = await harness(in: directory, offering: [new])
            harness.countries.download(old)
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the old build is installed") { harness.countries.isInstalled("SI") }
            check.holdTheNext()
            harness.countries.download(new)
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the update's check is out") { check.isHolding }

            harness.countries.delete("SI")
            try #require(!harness.countries.isInstalled("SI"))
            try await replaceWhileChecking(new, in: harness)

            #expect(harness.countries.isInstalled("SI"))
            #expect(harness.store.installed().map(\.country) == [new])
        }
    }
}
