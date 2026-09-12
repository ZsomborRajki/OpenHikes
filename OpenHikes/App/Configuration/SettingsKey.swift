//
//  SettingsKey.swift
//  OpenHikes
//
//  The `UserDefaults` / `@AppStorage` keys the app persists across launches,
//  and the defaults for the ones where "absent" and "false" are different
//  answers. Collected here rather than beside whichever feature happens to
//  read them first: the keys span selection, background tracking, tiles,
//  photos and iCloud sync, and several are written by one subsystem and read
//  by another. The string values are a storage contract — changing one
//  silently drops the stored setting on the next launch.
//
//  Nothing here configures networking. What the app puts on the radio is
//  decided from live conditions by ``TileNetworkPolicy``, not from a switch
//  the hiker had to find before they set off.
//

import Foundation

/// UserDefaults / `@AppStorage` key shared between the settings UI and the map.
nonisolated enum SettingsKey {
    static let tileProviderID = "settings.tileProviderID"
    /// Whether Background Trail Tracking is on, read by `BackgroundTrailTracker`
    /// at launch to decide whether to re-arm significant-change monitoring.
    static let backgroundTrackingEnabled = "settings.backgroundTrackingEnabled"
    /// The last-selected hike's `id.uuidString`, written by `OpenHikesModel` on
    /// every selection change. Serves two purposes: restoring the selection
    /// on a normal launch, and telling `BackgroundTrailTracker` which hike to
    /// match a fix against on a background relaunch, which has no in-memory
    /// selection to read.
    static let lastSelectedHikeID = "selection.lastHikeID"
    /// How far along the tracked hike the last background fix matched, in
    /// metres. `BackgroundTrailTracker` carries this across process launches so
    /// a relaunched match resumes from the previous position rather than
    /// re-deriving it; absent means "no continuity reference yet", which is why
    /// it is removed rather than zeroed when the selection changes.
    static let lastMatchedDistance = "trailTracking.lastMatchedDistance"
    /// The last weather reading and the subject it was for, as JSON. Written
    /// by ``WeatherReadingStore`` on every successful fetch and read once at
    /// launch, so the badge is on screen before the first network round trip
    /// rather than half a minute after it.
    ///
    /// A hint, never authoritative: it is drawn dimmed if it is old, by the
    /// same rule that dims a reading fetched in this session.
    static let lastWeatherReading = "weather.lastReading"
    /// Whether a photo taken in OpenHikes is also written to the system photo
    /// library. Off unless the user turns it on — and the only reason the app
    /// ever asks for photo-library access, which it does on the first save
    /// after the switch is flipped rather than when it is flipped.
    static let savePhotosToLibrary = "settings.savePhotosToLibrary"
    /// Whether hikes and their photos are mirrored through the user's private
    /// iCloud database. Read by ``CloudSyncCoordinator`` at launch, and the
    /// only one of the three reasons sync might be idle that the app decides
    /// for itself — the other two are the Apple Account and the test guard.
    static let cloudSyncEnabled = "settings.cloudSyncEnabled"
    /// Whether an active recording or followed trail puts a Live Activity on
    /// the Lock Screen and in the Dynamic Island. Read by
    /// ``HikeLiveActivityController`` on every update rather than captured, so
    /// turning it off mid-walk takes the activity down on the next fix.
    ///
    /// This is the app's half of the answer; the system's per-app Live
    /// Activities switch is the other half, and both have to say yes.
    static let liveActivitiesEnabled = "settings.liveActivitiesEnabled"
    /// The last entitlement ``MapEntitlementStore`` resolved, remembered so a
    /// cold launch draws the right map before StoreKit answers.
    ///
    /// Deliberately *not* synced, and deliberately not authoritative: it is a
    /// hint about this device's last known answer, overwritten the moment
    /// `Transaction.currentEntitlements` returns. See
    /// ``MapEntitlementStore/init(defaults:currentEntitlements:)`` for what it
    /// is and is not for.
    static let lastKnownMapEntitlement = "purchases.lastKnownMapEntitlement"
    /// Whether the app may notice that a paused hike has started moving again,
    /// or that a running one has stopped, and say so. Read by
    /// ``MovementReminderController`` on every decision rather than captured,
    /// so turning it off mid-hike stops the next reminder — and read *before*
    /// a pause arms anything, which is what keeps a pause exactly as cheap as
    /// it was for a hiker who does not want them.
    static let movementRemindersEnabled = "settings.movementRemindersEnabled"
    /// Whether the screens a live hike is watched from may hold the display
    /// awake. Read by ``ScreenWakePolicy`` through the modifier on those
    /// screens rather than captured, so turning it off puts the idle timer
    /// back without leaving the screen — and it is only ever *one* of the
    /// three answers that have to agree, the others being a live subject and
    /// a foreground app.
    static let keepScreenAwake = "settings.keepScreenAwake"
    /// The name a hiker's shared hikes are published under, as they last
    /// typed it.
    ///
    /// Remembered rather than asked for every time, and asked for rather than
    /// derived: the alternative is `CKUserIdentity`, which needs a
    /// discoverability prompt about the hiker's Apple Account and hands back
    /// a name they never chose to attach to a trail. This is the one they did.
    ///
    /// Deliberately not synced through ``SyncedSettings``. It travels on the
    /// submission itself, and a value that mirrored as well would be a second
    /// copy of the same fact that could disagree with what was published.
    static let communityAuthorName = "community.authorName"
    /// The people this device has blocked, JSON-encoded — see
    /// ``CommunityBlockList``, which owns the shape and the reasoning.
    ///
    /// Deliberately not synced through ``SyncedSettings``, for the reason
    /// browsing needs no account in the first place: a block has to work on a
    /// signed-out phone, and a value that only travelled for hikers with
    /// iCloud on would be a feature that quietly exists for some of them. The
    /// cost is that the list does not follow the hiker to a new phone, which
    /// is the smaller half — they can block again, and the alternative is a
    /// block that does not work at all where there is nothing to sync with.
    static let communityBlockedAuthors = "community.blockedAuthors"
}

/// Defaults for keys where "absent" and "false" are different answers, so the
/// settings screen and every non-SwiftUI reader start from the same value.
nonisolated enum SettingsDefault {
    /// Off. A second copy in the user's photo library is a reasonable thing to
    /// want and an unreasonable thing to assume: it costs storage, it mixes
    /// trail pictures into a library the user curates themselves, and it is
    /// the only thing that would make the app ask for photo-library access at
    /// all. The app's own copy is the one the hike depends on either way.
    static let savePhotosToLibrary = false
    /// On. Unlike the photo-library switch this costs the user nothing they
    /// did not already have — it is their own private iCloud storage, holding
    /// data they created, readable by nobody else — and the failure it
    /// prevents is the one people notice: a replaced phone that opens to an
    /// empty hikes list because a switch was never found.
    static let cloudSyncEnabled = true
    /// On. The walk is already happening and the phone is already awake for
    /// it — the location background mode runs for the whole hike — so the
    /// activity costs a redraw every twenty seconds rather than any new
    /// wakeups, and it is the difference between glancing at a Lock Screen and
    /// unlocking a phone with wet gloves on. The system's own per-app switch
    /// is still the hiker's veto.
    static let liveActivitiesEnabled = true
    /// On. The reminder the hiker never sees costs nothing: a paused
    /// recording is watched by the cheapest delivery Core Location has, and a
    /// paused walk is watched by fixes that were arriving anyway. The failure
    /// it prevents is the expensive one — a hike whose second half is missing
    /// because the hiker set off from lunch without tapping Resume, which no
    /// later screen can put right.
    static let movementRemindersEnabled = true
    /// Off. The display is the largest single consumer on the device, and a
    /// walk is measured in hours — so the hiker who has not asked for this
    /// keeps every bit of what the other energy policies buy them. The case
    /// it exists for is narrow and real enough to be worth a switch, and
    /// narrow enough not to be worth assuming: see ``ScreenWakePolicy``.
    static let keepScreenAwake = false
}
