//
//  AppLaunchEnvironment.swift
//  OpenTrails
//
//  Facts about *how this process was launched* that app-scoped startup work
//  has to branch on. One definition, because two copies of the same guard
//  drift and only one of them gets fixed.
//

import Foundation

nonisolated enum AppLaunchEnvironment {
    /// Whether this process was launched to host a test bundle.
    ///
    /// Both test bundles are hosted by the app, so it launches — and runs its
    /// `init`s and `.task`s — before a single test does. Startup work that
    /// writes shared state (a widget payload in the App Group, a recovered
    /// recording journal) therefore lands underneath suites whose whole
    /// subject is that state. It's a race no test can win, so the writers
    /// stay behind this flag.
    static let isHostingTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
