//
//  RetiredDeviceReportsSweepTests.swift
//  OpenHikesTests
//
//  The launch sweep that deletes the reports Settings ▸ Device Reports left
//  in Application Support after the screen was removed.
//
//  Each test points the sweep at a folder of its own under the temporary
//  directory. The default is the host app's real Application Support, and
//  these tests delete files on purpose.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Retired device reports sweep")
struct RetiredDeviceReportsSweepTests {
    private static func sandbox() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "retired-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("the reports folder goes whole, and nothing beside it")
    func removesTheFolder() async throws {
        let root = Self.sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appending(path: "FieldMetrics", directoryHint: .isDirectory)
        let neighbour = root.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: reports.appending(path: "report.json"))

        await OpenHikesModel.removeRetiredDeviceReports(at: reports)

        #expect(!Self.exists(reports))
        #expect(Self.exists(neighbour))
    }

    @Test("an install that never had any reports is left alone")
    func absentFolderIsANoOp() async {
        let root = Self.sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await OpenHikesModel.removeRetiredDeviceReports(at: root.appending(path: "FieldMetrics"))

        #expect(!Self.exists(root))
    }

    /// The one fact the sweep cannot check for itself: that it looks where
    /// the removed store wrote.
    @Test("the default is the folder the removed store used")
    func defaultIsTheStoresFolder() {
        let directory = OpenHikesModel.retiredDeviceReportsDirectory
        #expect(directory.lastPathComponent == "FieldMetrics")
        #expect(
            directory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL
        )
    }
}
