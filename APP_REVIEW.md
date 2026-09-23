# Notes for App Review

What goes in App Store Connect's **App Review Information → Notes** field,
written down once here rather than retyped from memory at each submission.

Everything below is a claim about the binary being submitted. A change to what
the app does in the background, or to which switch controls it, changes this
file in the same commit — a note that has drifted from the build is worse than
no note, because a reviewer checks it against what the phone does.

## Background location (2.5.4, 5.1.1)

Two separate things, and reviewers ask about them together. Always
authorization is one feature and the `location` background mode is another;
they are declared for different halves of the app and neither stands in for the
other.

### Always location — the widget and the Live Activity, opt-in behind a Settings toggle

Paste-ready:

> OpenHikes uses Always location for the Home Screen widget and the Live
> Activity, and it is opt-in behind a Settings toggle. The toggle is Settings →
> Background Trail Tracking, off by default, and turning it on is the only
> thing in the app that asks for Always access. What it buys is a widget and a
> Live Activity that keep showing the hiker's progress along the trail they
> selected while the app is not open — a hiker who locks the phone and keeps
> walking sees a panel that is still telling the truth. The same feed notices
> when the hiker reaches that trail and, if nothing is being walked, posts one
> notification asking whether to start the hike; it starts nothing on its own.
> With the toggle off,
> the app never requests Always authorization and does nothing in the
> background for either surface.
>
> The feed is significant-location-change monitoring, not continuous updates,
> and it is armed only when all four of these hold: the toggle is on, Always
> access is granted, a trail is selected, and the hiker is near that trail. A
> phone at home with a trail selected from last week is monitoring nothing.

This is the string a hiker reads in the prompt, and it says the same thing:

> OpenHikes uses Always location, only when you turn on Background Trail
> Tracking in Settings, to keep your Home Screen widget and Live Activity
> showing your progress along the trail while the app isn't open, and to ask
> whether to start the hike when you reach it.

### The `location` background mode — recording a hike

Paste-ready:

> The `location` background mode is used by hike recording. While a hiker is
> recording a trail, OpenHikes keeps a continuous location feed and a
> `CLBackgroundActivitySession` so the track is not lost with the screen off or
> the phone in a pocket — which is the whole of what a recorded hike is. It
> starts when the hiker taps Record and stops when they save or discard the
> recording; the app records nothing it was not asked to record.
>
> This is also why the system's background-location indicator appears during a
> recording and not while Background Trail Tracking is merely on:
> significant-location-change monitoring needs neither the background mode nor
> `allowsBackgroundLocationUpdates`, and the widget's feed uses neither.

### How a reviewer can see both

1. **Always / the widget and the Live Activity.** Settings → Background Trail
   Tracking. Turning it on is what raises the Always prompt; turning it off
   takes the feature down where it was turned off. Open a hike, follow the
   trail, and the widget and Live Activity carry that trail's progress.
2. **The background mode / recording.** Record a hike from the sheet. The
   location indicator is up for as long as the recording is, and goes when the
   recording is saved or discarded.
3. **The watch.** Record a hike on the paired watch. The workout session is
   what holds it up with the wrist down, and it ends with the recording.

## The watch app — its own background declarations, and the one Health read

The submitted binary embeds a watchOS app, `OpenHikesWatch`. Its background
entitlements are not the phone's and are not covered by either section above,
and it is the only part of the app that reads anything from HealthKit.

Paste-ready:

> The app embeds an Apple Watch app that records a hike on the watch alone. It
> asks for When In Use location on the watch and never asks for Always there:
> the Always feature described above is the phone's widget and Live Activity,
> and it has no watch half.
>
> The watch declares two background keys, both for recording and neither
> shared with the phone. `WKBackgroundModes` carries `workout-processing`,
> claimed by starting an `HKWorkoutSession`, which is the only thing watchOS
> offers that keeps a recording running with the wrist down. `UIBackgroundModes`
> carries `location` — an iOS key in a watchOS Info.plist deliberately, because
> Core Location checks that key on watchOS too and refuses
> `allowsBackgroundLocationUpdates` without it. Both begin when the hiker taps
> Record on the watch and end when the recording stops; following a trail
> without recording it starts neither.
>
> HealthKit on the watch asks to share the workout type and to read heart rate,
> and nothing else. The workout the live builder assembles is **discarded** on
> every path out of a recording rather than finished, because the phone already
> writes the finished hike to Health once and two writers would file the same
> walk twice — the watch is not a second writer. The heart rate is shown on the
> recording screen while the walk runs: it is not stored, not added to the
> hike, and not sent to the phone.

The strings a hiker reads on the watch say the same thing, and are in
`OpenHikesWatch/Info.plist`:

> OpenHikes reads your heart rate from Health while you are recording a hike, so
> the watch can show it as you walk. Nothing else in Health is read.

> OpenHikes starts a hiking workout in Health while you record on your watch,
> which is what keeps the recording running with the screen off. The workout
> itself is not saved — your iPhone saves the finished hike.

## Where these facts live in the repository

- The phone's purpose strings are in `OpenHikes/Info.plist`, all of them, and
  `InfoPlistContractTests` reads them back out of the built bundle. The watch's
  are in `OpenHikesWatch/Info.plist`, which no test reaches — there is no watch
  test bundle — so they are checked by reading them.
- The Always feature is `BackgroundTrailTracker`; its file header carries the
  argument for why significant-change monitoring is the right feed and what it
  still costs.
- The phone's recording half is `HikeRecorder+State.swift`, the only place on
  iOS that touches `allowsBackgroundLocationUpdates` or
  `CLBackgroundActivitySession`. The watch has its own and shares neither
  file nor entitlement: `OpenHikesWatch/Recording/WatchRecorder.swift` sets
  `allowsBackgroundLocationUpdates` and owns the `HKWorkoutSession`, and
  `OpenHikesWatch/Info.plist` carries the two background keys and the two
  Health purpose strings.
- The switch is `SettingsKey.backgroundTrackingEnabled`, drawn by
  `SettingsView.backgroundTrackingSection`, whose footer says the same thing
  the prompt does.
