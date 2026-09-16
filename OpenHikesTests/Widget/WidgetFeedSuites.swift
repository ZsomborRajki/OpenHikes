//
//  WidgetFeedSuites.swift
//  OpenHikesTests
//
//  "Widget feeds", split out of WidgetFeedTests.swift so that a file declares
//  one @Suite. That file's header still holds the context the two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

/// Both child suites share one App Group file, so they must not run beside
/// each other even when they are selected together.
@Suite("Widget feeds", .serialized, .enabled(if: SharedStoreProbe.isAvailable))
struct WidgetFeedSuites {}
