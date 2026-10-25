//
//  ForegroundContinuation.swift
//  OpenHikesShared
//
//  Carrying an intent on in the app, on every release the app supports.
//
//  iOS 26 replaced `ForegroundContinuableIntent` with an intent's
//  `supportedModes` and `continueInForeground(_:alwaysConfirm:)`, and below
//  26 only the protocol's `requestToContinueInForeground(_:continuation:)`
//  exists. They are one feature under two spellings — the deprecation tells a
//  conformance to put `.foreground(.dynamic)` in `supportedModes` instead —
//  and both keep the property every caller here depends on: once the app is
//  in front, the *same* `perform()` carries on. The call after this one is the
//  one that asks Core Location, and its prompt can only appear in the
//  foreground. `needsToContinueInForegroundError` would not do on either side
//  of 26: it re-runs `perform()`, and the re-run finds the same unanswered
//  authorization, because nothing between the two runs asked.
//
//  So an intent that hands off conforms to `ForegroundContinuableIntent` and
//  declares `supportedModes` as well: the conformance is what lets the older
//  call be written at all, and `supportedModes` is what iOS 26 reads.
//

import AppIntents

public extension ForegroundContinuableIntent {
    /// Asks the hiker to carry on in the app, and returns once it is in front.
    func askToContinueInForeground(_ dialog: IntentDialog) async throws {
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            try await continueInForeground(dialog)
        } else {
            try await requestToContinueInForeground(dialog)
        }
    }
}
