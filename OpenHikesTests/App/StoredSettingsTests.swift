//
//  StoredSettingsTests.swift
//  OpenHikesTests
//
//  `StoredSettings` stands in for four `@AppStorage`s, so it has to read what
//  they read — the same fallbacks for a key nothing has written — and follow
//  every writer they followed, while waking its readers only for the key that
//  changed. Why it exists at all is `AppStorageInvalidationTests`.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Stored settings")
struct StoredSettingsTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "StoredSettingsTests-\(UUID().uuidString)"))
    }

    @Test("an untouched suite reads the defaults the @AppStorage declarations had")
    func untouchedSuiteReadsTheDefaults() throws {
        let settings = StoredSettings(defaults: try defaults())

        #expect(settings.tileProviderID == TileProvider.default.id)
        #expect(settings.showsHikingRoutes == SettingsDefault.showsHikingRoutes)
        #expect(settings.hikeListSort == HikeListSort.newest.rawValue)
        #expect(settings.savesPhotosToLibrary == SettingsDefault.savePhotosToLibrary)
    }

    @Test("a write made elsewhere is read back before the write returns")
    func followsWritesMadeElsewhere() throws {
        let defaults = try defaults()
        let settings = StoredSettings(defaults: defaults)

        // What the settings screen's `@AppStorage` bindings and iCloud's
        // mirror do: write the suite, not this.
        defaults.set("stamen-terrain", forKey: SettingsKey.tileProviderID)
        defaults.set(!SettingsDefault.showsHikingRoutes, forKey: SettingsKey.showsHikingRoutes)
        defaults.set(HikeListSort.longest.rawValue, forKey: SettingsKey.hikeListSort)
        defaults.set(!SettingsDefault.savePhotosToLibrary, forKey: SettingsKey.savePhotosToLibrary)

        #expect(settings.tileProviderID == "stamen-terrain")
        #expect(settings.showsHikingRoutes == !SettingsDefault.showsHikingRoutes)
        #expect(settings.hikeListSort == HikeListSort.longest.rawValue)
        #expect(settings.savesPhotosToLibrary == !SettingsDefault.savePhotosToLibrary)
    }

    @Test("a write beside a setting wakes nobody reading it")
    func unrelatedWritesWakeNoReader() async throws {
        let defaults = try defaults()
        let settings = StoredSettings(defaults: defaults)
        let provider = ObservationCounter { _ = settings.tileProviderID }
        let routes = ObservationCounter { _ = settings.showsHikingRoutes }
        await provider.settle()

        for fix in 1...5 {
            defaults.set(Double(fix) * 25, forKey: SettingsKey.lastMatchedDistance)
        }
        defaults.set("stamen-terrain", forKey: SettingsKey.tileProviderID)
        await provider.settle()

        #expect(provider.count == 1, "the one write to its own key, and nothing for the five beside it")
        #expect(routes.count == 0)
    }

    @Test("the list's order is remembered where the next launch reads it")
    func listOrderIsWrittenThrough() throws {
        let defaults = try defaults()
        let settings = StoredSettings(defaults: defaults)

        settings.setHikeListSort(HikeListSort.longest.rawValue)

        #expect(settings.hikeListSort == HikeListSort.longest.rawValue)
        #expect(defaults.string(forKey: SettingsKey.hikeListSort) == HikeListSort.longest.rawValue)
        #expect(StoredSettings(defaults: defaults).hikeListSort == HikeListSort.longest.rawValue)
    }
}
