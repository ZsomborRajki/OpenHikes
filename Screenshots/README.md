# App Store screenshots

Everything needed to produce the App Store listing's screenshot set, and the
reasoning behind the parts that are not obvious.

## What App Store Connect actually requires

**One set, at 6.9".** Since App Store Connect's 2025 change an iPhone-only app
uploads a single 6.9" set — 1320 × 2868 — and every smaller size is scaled from
it. OpenHikes is `TARGETED_DEVICE_FAMILY = 1`, so there is no iPad set at all.

**Between one and ten of them.** Not ten: only the first three appear in search
results, and every frame past the first few is one more thing to re-shoot when
the UI moves. The nine captured here are already more than most listings use.

The order below is the upload order, and it is the order the frames are named
in, because App Store Connect orders screenshots by the order they arrive.

| # | Frame | What it has to say |
|---|---|---|
| 1 | `01-trail-and-its-photos` | The whole walk, its photographs, and one of them open |
| 2 | `02-photos-along-the-trail` | The gallery those photographs land in |
| 3 | `03-nearby-trails` | Published hikes and waymarked OSM routes, listed and pinned |
| 4 | `04-statistics-and-profile` | Is this a walk or a day out |
| 5 | `05-recording-a-hike` | It records, with live figures and the line so far |
| 6 | `06-offline-maps` | It works with no signal |
| 7 | `07-walk-summary` | A trail walked end to end |
| 8 | `08-draw-your-own-trail` | Plan Saturday: search three places and walk between them |
| 9 | `09-a-place-and-its-photos` | A place on the walk, kept with its own photographs |

Frame 8 is eighth deliberately rather than by arriving last. It is the only one
that shows the app *making* something rather than showing something, which is an
argument for putting it in the first three — and which of the eight those are is
a listing decision rather than a capture one, so it is appended here and moving
it is a rename. Nothing in the capture depends on the number.

It is the walk frame 1 is of, planned rather than imported: *Schönau am
Königssee*, *Kühroint* and *St. Bartholomä*, picked from the maker's own search,
routed in **Walking** mode. Apple's walking answer through those three stops runs
a median 7 m from the fixture's line — up to Kühroint and down the
Rinnkendlsteig — so the frame shows a real routed path rather than the straight
legs it used to. Hiking mode would ask Overpass, which no test launch may; the
frame's `--ui-test-live-maker` lets that one launch ask Apple for directions and
Stadia for the climb, which needs `OpenHikes/Secrets.plist` and spends one
Stadia call a run. Like frame 6 it is captured with `--ui-test-entitled`, since
the climb is a Pro feature.

Frame 9 is a place of the hiker's own, made from the map pill's *Add Place* on
the frame-1 hike: two of the stamped photographs picked in the system picker, a
name and a note, then *Add*. The pill puts the place where the elevation
graph's tracker is, so the frame taps the chart near its end first — the
lakeside stretch into St. Bartholomä — rather than leaving it at the start,
which is a car park in Schönau. It needs the stamped library like frames 1 and
2, and skips without it. The fixture itself carries no `<wpt>` on purpose: a
place in it would stand on the map in every other frame too.

## Capturing

```sh
Scripts/screenshots-light.sh             # the light set
Scripts/screenshots-dark.sh              # the dark set, files suffixed -dark
Scripts/screenshots.sh                   # both, one after the other
Scripts/screenshots-dark.sh --frame 03   # one frame, while debugging it
```

Each appearance has a script, a simulator (`OpenHikes Screenshots Light` /
`… Dark`, both `iPhone 18 Pro Max`), a derived-data directory and a set of
logs of its own. The two used to be one script run twice over one device, and
a dark pass that hung did so twenty minutes in, on a simulator the light pass
had just worked, with both passes in one log. Split, a dark failure is
reproduced with the dark script alone, and `--frame` narrows it to the one
test. The shared machinery is `Scripts/lib/screenshots.sh`.

A run erases its simulator, pins the status bar to 9:41 with a full battery
and full bars, pins the locale, grants location and photo access, adds the
stamped photographs, runs `ScreenshotUITests`, and writes the PNGs to
`Screenshots/Output/`. It only replaces its own appearance's files, and with
`--frame` only that frame's. The raw `xcodebuild` log and result bundle of
every attempt stay in `DerivedData/Screenshots-<appearance>/`, and the run
prints the path.

**Permissions are granted, never prompted for** — and location only for the
three frames that use it (03, 05, 08), which run as a group of their own after
the grant. The alert used to come up over the first tap of each of them; a
frame is a picture of the app, not of its permission prompt. The grant is not
given to the other six, because MapKit draws the location dot on every map of
an authorised app, and the hero frame grew a stale dot beside its trailhead the
one time it was.

**Dark appearance loses the first tap on a segmented picker.** Frames 03 and 08
used to be blamed on the location alert; with the alert gone, both still took
one tap in light and two in dark, every run. `tapUntilSelected` is the one
place that answers it. Whether a hiker's finger meets the same thing is not
known yet — this machine has no `Simulator.app` to tap by hand.

Frames that did not come out are re-run once, and only those. That is not
politeness: the community frame waits on a seeded browse answering, and that
wait can lose to a busy machine rather than to a bug. Each frame also has a
five-minute allowance, so a stuck one is killed with a spindump rather than
holding the pass.

`simctl addmedia` is given the whole library in one call with a deadline. One
photograph at a time, straight after boot, it once hung on the fourth for
twenty-six minutes before any test had run; when the deadline passes the
device is erased and prepared again, since the frames pick photographs by
their position in the library and a half-filled one cannot be added to.

The simulators are their own devices on purpose. A simulator that has been
used carries a tile cache, a photo library and possibly a simulated location
from an earlier run, and all three show up in a screenshot. It also means a
capture cannot collide with `Scripts/run-ui-tests.sh`, which claims its own
device for the same reason.

**The locale is pinned, to `en_IE`.** A simulator inherits the Mac's region, and
every figure in this app is formatted through the reader's locale on purpose —
so on a machine set to Hungary the whole set came out reading "2,4 km",
"2 000 m" and "2026. Sep 6.", all correct and none of it what an English listing
wants. `en_IE` is the one that is English, metric and writes a date most of the
world reads: `en_US` is imperial and `en_GB` prints road distances in miles,
which this app honours, so an `en_GB` frame reads "6.6 mi" beside a German place
name. `--locale en_US` is the right call for a US listing and will print miles.
The watch script has pinned its own for the same reason since it was written.

`ScreenshotUITests` is deliberately **not** in `suites` in
`Scripts/run-ui-tests.sh`: it asserts almost nothing and exists to produce
files, so `--all` leaves it alone. The screenshot scripts name it explicitly,
and they are what set up the device the frames assume.

## The route

`OpenHikes/SimulatedLocations/KoenigsseeRinnkendlsteig.gpx` —
Königssee → Kühroint → Rinnkendlsteig → St. Bartholomä. 10.6 km, 584 m to
1426 m, 912 m of ascent, four and three-quarter hours with the stops in.

Three separate things went into that file, and only the third is invented:

- **The line** is OpenStreetMap relation 222517 (`AV Weg 443`), fetched whole
  and chained end to end, so it sits exactly on the trail the map draws. The
  file carries the ODbL notice in its `<metadata><copyright>`.
- **The heights** are Stadia Maps' elevation service — the same vendor and the
  same endpoint `CuratedElevation` already uses — smoothed over a ±3-point
  window. Unsmoothed DEM samples put the ascent at 1123 m, which is 200 m of
  noise, and gave the speed model below spurious 40% gradients on 23 m
  segments.
- **The clock** is synthesised from a Tobler hiking function with three rest
  stops in it. That is what makes the overall and moving averages differ —
  2.23 against 2.75 km/h — which is the pair of figures the hike detail screen
  shows side by side and the reason it shows them.

Berchtesgaden rather than anywhere else because `CuratedTrailQuery`'s own
measurements were taken over this box. Re-measured while this was built: 94
`route=hiking` relations, 86 of them inside the 20 km span filter. The nearby
list has something in it here, which is not a safe assumption everywhere.

## Photographs

Frame 2 uses `--ui-test-seed-photos`, which generates its own images, so a
capture works with no photographs at all. They are gradients and scattered
shapes — fine for the layout, useless in a store listing.

For the real frame, put JPEGs in `Screenshots/Photos/` and stamp them:

```sh
Scripts/stamp-hike-photos.swift \
    OpenHikes/SimulatedLocations/KoenigsseeRinnkendlsteig.gpx \
    Screenshots/Stamped \
    Screenshots/Photos/*.jpg

Scripts/screenshots.sh --photos Screenshots/Stamped
```

The stamper rewrites each photograph's EXIF time and GPS position to a point
spread along the track, which is what lets the app's own matcher
(`LibraryPhotoMatch`) find them and pin each one to the trail. Without it a
stock photograph is invisible to that scan: the feature works and has nothing
to work on. Originals are not modified.

Times are written in UTC with an explicit `OffsetTimeOriginal`, and the GPS
timestamp is written too, because a bare `DateTimeOriginal` is read in the
reader's own zone — which would put every photograph an hour or two off the
walk on a machine that is not in the Alps.

**Licensing is the part to get right.** These end up in a public store listing,
so they need to be photographs there is a right to publish: your own, or
CC0 / Unsplash / Pexels. Avoid CC-BY — a store screenshot has nowhere to put
the attribution it requires. Both `Screenshots/Photos/` and
`Screenshots/Stamped/` are gitignored; stock images do not belong in this
repository's history.

## Framing, and the one thing that kept breaking it

Three of the frames position the map themselves, because the app will not do
it for them: every camera move in `MapCoordinator+RouteFitting.swift` frames
into the strip above a sheet at its *middle* detent, which on this device is
about a quarter of the screen. Correct for the app; too small for a hero shot.

So the hero frame pans and zooms the map by hand, measuring the photo pins
between gestures and correcting. The measuring matters — a drag lands short of
the vector it is given, and a zoom doubles whatever is left off-centre.

**Zoom with a double tap, never `XCUIElement.pinch`.** A pinch rotates the map
a little, and that cost the most time here by far: a few degrees off north
turns a walk that is six kilometres north-to-south and under two wide into a
diagonal that fits no frame at any zoom. The frame used to pinch, tap MapKit's
compass to turn the map back, and pan twice more to recover — three gestures
undoing one. A double tap only zooms, and `zoomMapInOneStep(in:)` asserts the
compass never appears. The same rule runs through the set: choose the gesture
that does only what the frame needs, and wait on its effect, rather than make
a gesture known to disturb the screen and correct afterwards.

## Before uploading

- The frames are 1320 × 2868. The scripts print each one's size;
  anything else is the wrong device.
- The OpenStreetMap attribution has to stay visible in every map frame. It is a
  licence condition, not decoration.
- Frame 6 is captured with `--ui-test-entitled`, so it shows a control that is
  behind OpenHikes Pro. That is honest — it is a real feature — but the listing
  text should not imply it is free.

## The Apple Watch set

```sh
Scripts/watch-screenshots.sh
```

That creates a dedicated `Apple Watch Ultra 4 (49mm)` simulator and a companion
iPhone, erases the watch, pairs the two, pins the locale, builds, installs, and
writes five PNGs at 422 × 514 to `Screenshots/WatchOutput/`. About four and a
half minutes, most of it deliberate waiting.

| # | Frame | What it has to say |
|---|-------|--------------------|
| 1 | `01-your-trails` | Your hikes, on your wrist |
| 2 | `02-the-trail-on-your-wrist` | The route on a real map — the reason to raise it |
| 3 | `03-how-much-is-left` | How far, how much is left, still on the trail |
| 4 | `04-recording-from-the-wrist` | It records on its own, with a heart rate |
| 5 | `05-your-iphone-s-hike` | Your iPhone's recording, driven from here |

### It is launched, not tapped

There is no watch equivalent of `ScreenshotUITests` and there is not going to
be one: `OpenHikesWatch` has no test bundle and no gate boots a watch
simulator, and `simctl` can install, launch and photograph a watch app but
cannot tap one.

So a frame is a *launch*. `Scripts/watch-screenshots.sh` launches the app once
per frame with that frame's `--ui-test-*` arguments, `WatchLaunchEnvironment`
parses them, and `SeededWatchFixture` puts the watch in the state they
describe. The payloads it builds are the real ones — a `WatchLibraryDigest`, a
`WatchTrailPackage`, a `WatchPhoneRecording` — because a watch simulator has no
paired phone and every screen in this app is drawn from something that arrives
over `WCSession`. The position on the trail is matched by the real
`WatchRouteTracker` rather than invented, so the figures on frame 3 are the
ones that trail and that place genuinely produce.

The route is the same Königssee walk the iPhone set uses, decimated to 128
points in `SeededWatchRoute.swift`.

This also replaces what looking at a watch screen used to cost: editing
`OpenHikesWatchApp`'s `WindowGroup` to point at the screen and putting it back
afterwards.

### Three things that are not like the iPhone set

- **The status bar cannot be pinned to 9:41.** `simctl status_bar override`
  answers "Status bar overrides not supported on this platform" on every
  watchOS device. The time in the frames is the time they were taken.
- **There is no light appearance.** `simctl ui … appearance` answers "Runtime
  does not support userInterfaceStyle", because watchOS has no light mode. One
  set, no `-dark` suffix.
- **The locale is pinned, to `en_IE`.** A simulator inherits the Mac's region,
  which here produced "4,2 km" and "2026. Sep 7.". `en_IE` is the English
  locale that is also metric — `en_US` is imperial and `en_GB` prints miles,
  which this app honours. `--locale en_US` for a US listing.

### When the map comes out grey

A green route on a flat grey grid is MapKit's placeholder, which is also what
this app genuinely looks like offline — so the frame is wrong in a way that
reads as deliberate. There are two causes and both are handled:

- **A paired watch fetches its tiles through its companion.** The watch's log
  says `[GeoServices:TileLoading] [Companion] … com.apple.nanomaps.xpc.
  GeoServices was invalidated`, with each request timing out after exactly
  60 seconds. The script launches `com.apple.Maps` on the companion to start
  that stack. Without it every map frame is grey; with it none are. This is
  the one to suspect first if the frames regress.
- **A cold cache is slow.** The device is erased every run, so the tiles are
  always fetched fresh. Map frames wait 60 seconds
  (`OPENHIKES_WATCH_MAP_SETTLE`) where a text frame waits 15 (`--settle`,
  which does not move the map wait).

`--no-pair` is the fallback: an unpaired watch uses its own network and always
draws its map, at the cost of a red crossed-out iPhone in every status bar.
`--no-erase` keeps the tile cache between runs.

### Pairing is done once

The pair survives both the erase and the simulators being shut down, so the
script only pairs when the pairing is not already right. That is not an
optimisation: re-pairing forces a sync, and a watch in the middle of one
reports no companion and starves MapKit for a minute or more — which looks
exactly like a bug in the app. A run that does have to pair waits the sync out
before capturing anything.

The companion also carries the **phone** app, which is why the paired path
builds the `OpenHikes` scheme rather than `OpenHikesWatch` (the iOS app embeds
the watch one, so it is still one build). watchOS mirrors the companion's app
list, and a watch app whose phone app is missing is an orphan that the pairing
sync deletes — some minutes in, which is the middle of a capture. The symptom
is `simctl launch` refusing with `FBSOpenApplicationServiceErrorDomain` code 4
for an app that was launching a minute earlier, and it survives a reboot,
because the app is genuinely gone.
