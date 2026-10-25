// The source guard catches hidden copy before a sync; these keys also prove
// that real shipping-target builds extract representative text in each area.

import Foundation
import Testing

extension StringCatalogTests {
    @Test("remaining app and widget copy is extracted", arguments: [
        ("OpenHikes", "Hiking"),
        ("OpenHikes", "Asphalt, concrete, paving stones"),
        ("OpenHikes", "This GPX file is too large to import."),
        ("OpenHikes", "Location access is needed to record a hike."),
        ("OpenHikes", "OpenHikes isn’t ready on your iPhone yet."),
        ("OpenHikes", "This hike is too short to share"),
        ("OpenHikes", "Couldn’t reach iCloud."),
        ("OpenHikes", "Still hiking?"),
        ("OpenHikes", "Recording your hike."),
        ("OpenHikes", "Keeps OpenStreetMap Free"),
        ("OpenHikes", "Newest First"),
        ("OpenHikes", "Arrows only"),
        ("OpenHikes", "today"),
        ("OpenWidget", "Select a trail"),
        ("OpenWidget", "Recording Hike"),
        ("OpenWidget", "Off trail"),
        ("OpenWidget", "Track points"),
        ("OpenWidget", "Pauses the hike being recorded, from its Lock Screen panel."),
        ("OpenHikesWatch", "Asking your iPhone for your trails…"),
    ])
    func remainingCopyReachesTheCatalog(folder: String, key: String) throws {
        let strings = try Self.catalog(in: folder)
        let entry = try #require(strings[key] as? [String: Any], "\(key) is missing from \(folder)")
        #expect(entry["extractionState"] as? String != "stale")
    }

    @Test("new count keys keep their singular wording")
    func remainingCountsHaveSingularVariations() {
        #expect(String(localized: "\(1) files couldn’t be imported.") == "1 file couldn’t be imported.")
        #expect(String(localized: "\(2) files couldn’t be imported.") == "2 files couldn’t be imported.")
        #expect(String(localized: "\(1) hikes") == "1 hike")
        #expect(String(localized: "\(2) hikes") == "2 hikes")
    }
}
