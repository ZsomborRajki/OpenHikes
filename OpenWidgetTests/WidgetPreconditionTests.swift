//
//  WidgetPreconditionTests.swift
//  OpenWidgetTests
//
//  "Widget preconditions", split out of TrailWidgetTests.swift so that a file
//  declares one @Suite. That file's header still holds the context the two
//  share.
//

import CoreLocation
import Foundation
import OpenHikesShared
import Testing
import WidgetKit

@Suite("Widget preconditions")
struct WidgetPreconditionTests {
    @Test("the App Group the widget reads from is reachable")
    func appGroupIsReachable() {
        guard !WidgetStoreProbe.isAvailable else { return }
        let message =
            "the App Group container \(SharedStore.appGroupID) is unreachable, so the widget suites were skipped"
        if WidgetStoreProbe.isStrict {
            Issue.record(Comment(rawValue: "Precondition not met: \(message)."))
        } else {
            print(
                "⚠︎ Skipped coverage — precondition not met: \(message)." +
                " Set OPENHIKES_REQUIRE_ALL_SUITES=1 to make this a failure."
            )
        }
    }
}
