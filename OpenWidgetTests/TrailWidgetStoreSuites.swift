//
//  TrailWidgetStoreSuites.swift
//  OpenWidgetTests
//
//  The parent of every suite here that writes the App Group.
//
//  There is one container per process and the widget reads whole files out of
//  it, so two suites that both call `SharedStore.clear()` in their `init()`
//  cannot run beside each other: swift-testing runs *top-level* suites in
//  parallel, and `.serialized` on each of them only orders that suite's own
//  tests. The trait has to sit above both, which is what this empty type is
//  for — the same arrangement, and the same reason, as `WidgetFeedSuites` in
//  the app test target.
//
//  `parallelizable: false` in `OpenHikes.xctestplan` does not cover this: it
//  governs how XCTest spreads a bundle across simulator clones, not what
//  swift-testing does inside one process.
//

import Testing

@Suite("Trail widget store", .serialized, .enabled(if: WidgetStoreProbe.isAvailable))
struct TrailWidgetStoreSuites {}
