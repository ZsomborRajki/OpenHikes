//
//  ModelConfigurationTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Model configuration")
struct ModelConfigurationTests {
    @Test("both persistent stores resolve inside the app's private Application Support")
    func storesBelongToTheApp() {
        let configurations: [ModelConfiguration] = [
            .openHikes(schema: Schema(OpenHikesSchema.hikeModels)),
            .openHikesLocal(schema: Schema(OpenHikesSchema.localStateModels)),
        ]

        for configuration in configurations {
            #expect(configuration.groupAppContainerIdentifier == nil)
            #expect(
                configuration.url.deletingLastPathComponent().standardizedFileURL
                    == URL.applicationSupportDirectory.standardizedFileURL,
                "\(configuration.name) must not use the widget's shared container"
            )
        }
    }
}
