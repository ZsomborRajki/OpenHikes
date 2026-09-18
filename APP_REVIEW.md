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
> walking sees a panel that is still telling the truth. With the toggle off,
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
> showing your progress along the trail while the app isn't open.

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

## Where these facts live in the repository

- The purpose strings are in `OpenHikes/Info.plist`, all of them, and
  `InfoPlistContractTests` reads them back out of the built bundle.
- The Always feature is `BackgroundTrailTracker`; its file header carries the
  argument for why significant-change monitoring is the right feed and what it
  still costs.
- The recording half is `HikeRecorder+State.swift`, which is the only place
  `allowsBackgroundLocationUpdates` and `CLBackgroundActivitySession` are
  touched.
- The switch is `SettingsKey.backgroundTrackingEnabled`, drawn by
  `SettingsView.backgroundTrackingSection`, whose footer says the same thing
  the prompt does.
