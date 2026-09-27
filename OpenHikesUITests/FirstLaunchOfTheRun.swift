//
//  FirstLaunchOfTheRun.swift
//  OpenHikesUITests
//

import XCTest

/// A launch spent on the install `xcodebuild` makes as a run starts, so that
/// no test's own launch is the one that meets it.
///
/// `xcodebuild` reinstalls the app once per invocation, a fraction of a second
/// before the first test launches it, and a launch that lands on that install
/// can reach the app with none of its arguments. The app then comes up as an
/// ordinary launch: the on-disk store and CloudKit rather than the in-memory
/// one, no `--ui-test-import-gpx`, a compact sheet — and the test fails a
/// step later, reading like a missing row. Measured on 2026-09-27 from the
/// simulator's own log: the install registered at 19:35:11.7, the launch
/// went out at 19:35:12.0 with one program argument where the test had set
/// three, and none of the eleven launches after it in that run met an
/// install or lost an argument. Only the first test of a run could fail this
/// way, so it looked like whichever test happened to sort first was flaky.
///
/// Absorbed by one throwaway launch, made and ended before the test's own.
/// `--ui-testing` alone, so if this is the launch that loses its arguments it
/// costs nothing but the seconds, and if it keeps them it touches no location
/// and no disk. Once per runner process, which is once per invocation.
@MainActor
enum FirstLaunchOfTheRun {
    private static var isAbsorbed = false

    static func absorbInstall() {
        guard !isAbsorbed else { return }
        isAbsorbed = true
        let throwaway = XCUIApplication()
        throwaway.launchArguments = ["--ui-testing"]
        throwaway.launch()
        throwaway.terminate()
    }
}
