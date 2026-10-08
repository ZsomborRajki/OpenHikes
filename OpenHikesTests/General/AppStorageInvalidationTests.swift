//
//  AppStorageInvalidationTests.swift
//  OpenHikesTests
//
//  `@AppStorage` re-runs the view that declares it on every write to its
//  `UserDefaults` — any key, from anywhere — and not only on writes to its
//  own. That is SwiftUI's behaviour rather than this app's, so it is pinned
//  here on a probe, beside the same probe reading `StoredSettings` instead,
//  which is what the always-on screens do now. The unrelated key written is
//  the one a followed trail writes each time it publishes the hiker's
//  position.
//
//  Each write is pushed through a layout pass of its own before the next, so
//  SwiftUI cannot fold several invalidations into one body and make the probe
//  look cheaper than it is.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing
import UIKit

/// The shape the map screen, the hikes list and the hike detail had.
private struct AppStorageProbe: View {
    let counter: BodyCounter
    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id

    var body: some View {
        counter.record()
        return Text(verbatim: tileProviderID)
    }
}

/// The shape they have now.
private struct StoredSettingsProbe: View {
    let counter: BodyCounter
    let settings: StoredSettings

    var body: some View {
        counter.record()
        return Text(verbatim: settings.tileProviderID)
    }
}

@MainActor
@Suite("App storage invalidation")
struct AppStorageInvalidationTests {
    /// Five writes of what a followed trail writes when it publishes the
    /// hiker's position.
    private static let unrelatedWrites = 5

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AppStorageInvalidationTests-\(UUID().uuidString)"))
    }

    private func host(_ view: some View, defaults: UserDefaults) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.defaultAppStorage(defaults))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Applies whatever the last write invalidated, now rather than later.
    private func render(_ window: UIWindow) {
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
    }

    @Test("a write to any key re-runs a body holding @AppStorage")
    func appStorageWakesForEveryWrite() async throws {
        let defaults = try defaults()
        let counter = BodyCounter()
        let window = try host(AppStorageProbe(counter: counter), defaults: defaults)
        defer { dismiss(window) }
        render(window)
        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        for fix in 1...Self.unrelatedWrites {
            defaults.set(Double(fix) * 25, forKey: SettingsKey.lastMatchedDistance)
            await settleDelegateHop(until: "the probe has re-run for write \(fix)") {
                render(window)
                return counter.count >= before + fix
            }
        }

        #expect(
            counter.count == before + Self.unrelatedWrites,
            "the premise: one body per write, and none of them to the key the probe reads"
        )
    }

    @Test("a body reading stored settings re-runs only for its own key")
    func storedSettingsWakeForTheirOwnKey() async throws {
        let defaults = try defaults()
        let settings = StoredSettings(defaults: defaults)
        let counter = BodyCounter()
        let window = try host(StoredSettingsProbe(counter: counter, settings: settings), defaults: defaults)
        defer { dismiss(window) }
        render(window)
        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        for fix in 1...Self.unrelatedWrites {
            defaults.set(Double(fix) * 25, forKey: SettingsKey.lastMatchedDistance)
            render(window)
        }
        // The positive effect, last: a write the probe does read, which it
        // must see — so the writes before it had every chance to be seen too.
        defaults.set("stamen-terrain", forKey: SettingsKey.tileProviderID)
        await settleDelegateHop(until: "the probe has re-run for its own key") {
            render(window)
            return counter.count > before
        }

        #expect(counter.count == before + 1, "five unrelated writes and one related one are one body")
    }
}
