//
//  OfflineCountryDownloadKeyTests.swift
//  OpenHikesTests
//
//  How a background task says which file it carries. A relaunch hands back
//  the session's tasks with nothing but their descriptions, so the label is
//  what ties a file landing after a quit to its country, and the name it is
//  staged under has to be the one the store looks for.
//

@testable import OpenHikes
import Testing

@Suite("Offline country download key")
struct OfflineCountryDownloadKeyTests {
    @Test("a task's label reads back as the file it was for", arguments: OfflineCountryManifest.Role.allCases)
    func roundTrip(role: OfflineCountryManifest.Role) {
        let key = OfflineCountryDownloadKey(country: "AT", build: "20261117", role: role)
        #expect(OfflineCountryDownloadKey(taskDescription: key.taskDescription) == key)
    }

    @Test("a label the app did not write is nobody's", arguments: ["", "AT 20261117", "AT 20261117 roads", "a b c d"])
    func foreignLabel(description: String) {
        #expect(OfflineCountryDownloadKey(taskDescription: description) == nil)
    }

    /// A file that lands after a relaunch is staged under this name, and the
    /// model looks for it under the manifest's.
    @Test("a file is staged under the name the manifest gives it")
    func stagedName() {
        let basemap = OfflineCountryDownloadKey(country: "AT", build: "20261117", role: .basemap)
        let extras = OfflineCountryDownloadKey(country: "AT", build: "20261117", role: .extras)
        #expect(basemap.fileName == "AT-20261117.pmtiles")
        #expect(extras.fileName == "AT-extras-20261117.pmtiles")
        let detail = OfflineCountryDownloadKey(country: "US-CO", build: "20261117", role: .detail)
        let detailExtras = OfflineCountryDownloadKey(country: "US-CO", build: "20261117", role: .detailExtras)
        #expect(detail.fileName == "US-CO-detail-20261117.pmtiles")
        #expect(detailExtras.fileName == "US-CO-detail-extras-20261117.pmtiles")
        let trails = OfflineCountryDownloadKey(country: "US-CO", build: "20261117", role: .trails)
        #expect(trails.fileName == "US-CO-trails-20261117.pmtiles")
        let elevation = OfflineCountryDownloadKey(country: "US-CO", build: "20261117", role: .elevation)
        #expect(elevation.fileName == "US-CO-elevation-20261117.pmtiles")
    }
}
