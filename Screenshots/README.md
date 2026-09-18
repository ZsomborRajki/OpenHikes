# App Store screenshots

Everything needed to produce the App Store listing's screenshot set, and the
reasoning behind the parts that are not obvious.

## What App Store Connect actually requires

**One set, at 6.9".** Since App Store Connect's 2025 change an iPhone-only app
uploads a single 6.9" set — 1320 × 2868 — and every smaller size is scaled from
it. OpenHikes is `TARGETED_DEVICE_FAMILY = 1`, so there is no iPad set at all.

**Between one and ten of them.** Not ten: only the first three appear in search
results, and every frame past the first few is one more thing to re-shoot when
the UI moves. The seven captured here are already more than most listings use.

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

## Capturing

```sh
Scripts/screenshots.sh                      # light and dark
Scripts/screenshots.sh --appearance light   # one set, twice as fast
```

That creates a dedicated `iPhone 18 Pro Max` simulator, erases it, pins the
status bar to 9:41 with a full battery and full bars, runs
`ScreenshotUITests`, and writes the PNGs to `Screenshots/Output/`. With
`--appearance both`, which is the default, the dark frames are written again
with a `-dark` suffix.

Each pass is retried once before the script gives up. That is not politeness:
the community scenario waits on a seeded browse answering, and that wait loses
to a busy machine rather than to a bug — reliably so on the second pass, when
the first has just finished working the same simulator.

The simulator is its own device on purpose. A simulator that has been used
carries a tile cache, a photo library and possibly a simulated location from an
earlier run, and all three show up in a screenshot. It also means a capture
cannot collide with `Scripts/run-ui-tests.sh`, which claims its own device for
the same reason.

`ScreenshotUITests` is deliberately **not** in `suites` in
`Scripts/run-ui-tests.sh`: it asserts almost nothing and exists to produce
files, so `--all` leaves it alone. `Scripts/screenshots.sh` names it
explicitly, and that script is what sets up the device the frames assume.

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

So the hero frame pans and pinches the map by hand, measuring the photo pins
between gestures and correcting. The measuring matters — a drag lands short of
the vector it is given, and a pinch multiplies whatever is left off-centre.

**`XCUIElement.pinch` also rotates the map a little.** That cost the most time
here by far. A few degrees off north turns a walk that is six kilometres
north-to-south and under two wide into a diagonal that fits no frame at any
zoom, and every attempt to pan it into place crops the other end. MapKit shows
its compass once the map is off north, and tapping that compass is the fix —
see `restoreNorth(in:)`. If a map frame ever looks inexplicably cropped, check
for the compass in the corner before touching the zoom.

## Before uploading

- The frames are 1320 × 2868. `Scripts/screenshots.sh` prints each one's size;
  anything else is the wrong device.
- The OpenStreetMap attribution has to stay visible in every map frame. It is a
  licence condition, not decoration.
- Frame 6 is captured with `--ui-test-entitled`, so it shows a control that is
  behind OpenHikes Pro. That is honest — it is a real feature — but the listing
  text should not imply it is free.
