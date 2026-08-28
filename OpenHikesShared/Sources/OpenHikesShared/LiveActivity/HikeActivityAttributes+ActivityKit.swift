//
//  HikeActivityAttributes+ActivityKit.swift
//  OpenHikesShared
//
//  The one line that makes ``HikeActivityAttributes`` an ActivityKit payload,
//  kept apart from the payload itself.
//
//  `ActivityAttributes` is `@available(macOS, unavailable)` — not merely
//  absent, explicitly refused — and this package is compiled for macOS by
//  `swift test`, which is where its whole suite runs and where CI checks it
//  twice. Conforming in the same file as the type would therefore trade the
//  package's testability for one protocol conformance the tests cannot reach
//  anyway.
//
//  So the split is deliberate and load-bearing: everything a test can assert
//  lives in the payload and in `HikeActivityPresentation`, and this file adds
//  nothing but the conformance iOS needs to hand the value to the system.
//  `#if os(iOS)` rather than `canImport(ActivityKit)`, because the framework
//  *is* importable on macOS — it is the protocol inside it that is not.
//

#if os(iOS)
import ActivityKit

extension HikeActivityAttributes: ActivityAttributes {}
#endif
