//
//  TrailWidgetConfiguration.swift
//  OpenHikesShared
//
//  What a hiker can choose about a placed Trail widget: which trail it shows,
//  or nothing, which means "whatever is selected".
//
//  ## Why it is no longer empty
//
//  It was, and *Edit Widget* opened on an empty sheet. The widget drew whatever
//  `SettingsKey.lastSelectedHikeID` last pointed at, with two consequences
//  (#468): two widgets could never show two trails, and the subject of a
//  placed widget moved for reasons off-screen — opening a hike to check its
//  length re-pointed every widget on the Home Screen.
//
//  The recording takeover is a deliberate, documented exception to selection
//  ownership. That was not: it was the absence of a choice.
//
//  ## Why `nil` is the default and has to stay the default
//
//  **An unconfigured widget must keep doing exactly what it does now.** People
//  already have these on their screens, and `AppIntentConfiguration`'s whole
//  migration argument — the kind is unchanged, which is what carries
//  already-placed widgets across — is worth nothing if the migration silently
//  blanks them. So `nil` means follow the selection, which is what every
//  existing widget will decode as.
//
//  ## Why it is in the shared package
//
//  Both processes need the type. The widget declares it; the **app** reads it
//  back out of `WidgetCenter.getCurrentConfigurations()` to learn which trails
//  are pinned, which is what decides the snapshots it keeps warm — see
//  `SharedHikeCataloguePublisher`. A type in `OpenWidget/` is not visible to
//  the app target any more than one in `OpenHikes/` is to the widget.
//

import AppIntents

/// The Trail widget's configuration.
///
/// Not `nonisolated`: `@Parameter` wraps a mutable stored property, and
/// `nonisolated` cannot be applied to one — the same constraint
/// ``HikeEntity`` carries.
public struct TrailWidgetConfiguration: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Trail"
    // periphery:ignore - an optional `AppIntent` requirement, read through
    // the AppIntents metadata rather than by any call site.
    public static let description = IntentDescription(
        "Shows a trail you choose, or your selected trail, or a hike currently being recorded."
    )

    /// The trail this widget is pinned to, or `nil` to follow the app's
    /// selection — see this file's header for why `nil` is load-bearing.
    ///
    /// The picker behind it is ``HikeEntityQuery``, which reads the App Group
    /// catalogue rather than the app's store precisely so that it can run
    /// here, in a process that has neither.
    @Parameter(title: "Trail")
    public var hike: HikeEntity?

    public init() {
        // `nil` — follow the selection, which is what every already-placed
        // widget decodes as.
    }

    public init(hike: HikeEntity?) {
        self.hike = hike
    }
}
