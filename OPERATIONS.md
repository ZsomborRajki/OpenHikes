# OPERATIONS.md

What is run by hand around the app, and what is live where it runs: releases,
CloudKit schema promotes, the tile server's refresh and the squares built for
it, and the state each was last checked in. It also says how to set up the
iPhone Duo simulator and run the app on a Mac outside Xcode.

None of this is needed to change the app's code, so it stays out of
[`AGENTS.md`](AGENTS.md), which every agent session loads whole. `AGENTS.md`
keeps the rules a change must not break and points here for the steps. Cite
this file by section name, as `AGENTS.md` is cited.

## Releasing

- **Upload with the TestFlight workflow.** `.github/workflows/testflight.yml`
  runs on demand with the version to ship (`gh workflow run testflight.yml -f
  version=<version> -f cloudkit_promoted=true`). It archives the branch it is
  run from, uploads it and pushes its tag. Its header lists the `testflight`
  environment's secrets and how to set them.
  - It stamps the version at build time and commits nothing, because `main`
    takes no pushes. So the tags, not `project.pbxproj`, record what shipped.
  - Each version's builds start at 1. After that, the build number is one
    past the highest build tagged or committed for that version
    (`Scripts/release-version.sh`).
  - It writes the gitignored `OpenHikes/Secrets.plist` (the Stadia and
    Thunderforest keys) from its secrets, then runs
    `Scripts/check-release-secrets.sh` on that file and on the archived app's
    copy. An archive succeeds without the file, shipping paid map styles that
    draw nothing, and `ci.yml` archives without keys on purpose.
- **Promote the CloudKit schema before uploading.** An App Store Connect
  upload, TestFlight included, is signed for the production container, and a
  save there cannot add a field. Check production against the model first
  (*CloudKit deployment state*, then *Promoting a CloudKit field*). Nothing
  can check it for the workflow, so it refuses to start until
  `cloudkit_promoted` is ticked.
- **Every archived commit carries a tag**,
  `v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`, which the workflow pushes.
  There are no release branches, so a tag is the only way to map an Organizer
  crash report to a revision. Add a GitHub Release for App Store builds.

## CloudKit

The rules a synced field is held to are *CloudKit* in `AGENTS.md`.

### Promoting a CloudKit field

A new synced field must be promoted before any build that writes it reaches
the production environment, and an App Store Connect upload, TestFlight
included, does:

1. `xcrun cktool export-schema`, then add the line.
2. `validate-schema`, then `import-schema --environment development`.
3. Re-export and check the result.
4. Promote in the Console. `cktool` has no promote command.

Field shapes:

| Swift type | CloudKit field |
|---|---|
| `String?` | `STRING QUERYABLE SEARCHABLE SORTABLE` |
| `Data?` or a `Codable` array, without external storage | `BYTES QUERYABLE SORTABLE` |
| `Int` or `Bool` | `INT64 QUERYABLE SORTABLE` |
| `Double` or `Double?` | `DOUBLE QUERYABLE SORTABLE` |

A hand-declared shape is inferred, so let a development build save the field
once before promoting. An `@Attribute(.externalStorage)` column, such as
`Hike.route`, also mirrors through a `CD_<name>_ckAsset` asset field: check
that the development export has it, and promote both.

The public database's types change the same way, by import, and their index
list is read again after every change (*A new field arrives indexed* in
`AGENTS.md`).

### CloudKit deployment state

Checked 2026-11-21. Development and production both export
`md5 74a5b5d91372f08c92c3af7402df7892`. Both have the two trail-square record
types, `CuratedTrailCell` and `CuratedTrailManifest`, neither with an index.
Both hold the same build of all four sets of squares, from OpenStreetMap as of
2026-11-17 23:00 UTC, each marked as the whole world under its own manifest
(checked 2026-11-18): `trails1_manifest`, `routes1_manifest`,
`places1_manifest` and `graph1_manifest`. Builds v1.5-1 to v1.7-1 read them,
and nothing later does (*The public database's copies of the squares*). Both
have a column for every attribute in `MirroredCloudKitSchema.recordTypes`.
The only live columns the contract does not name are SwiftData's own
`CD_entityName`, the to-one reference columns that the contract lists as
relationships, and the `CD_route_ckAsset`, `CD_rawRoute_ckAsset` and
`CD_originalRoute_ckAsset` asset fields of the three external-storage
attributes. Re-export before believing these numbers, and update this
paragraph when they move. Deployment facts live here, not in code.

## The tile server

The server is not in this repository. It is a Worker and an R2 bucket. What
the app expects of it is *Tiles*, *The offline countries* and *The trail
squares* in `AGENTS.md`.

### Refreshing the tile server

A refresh is a run of commands, each safe to run again. Each script's header
has its options.

1. `Scripts/trail-cells.sh update-planet <planet.osm.pbf>`, then
   `Scripts/vector-extras.sh build <planet.osm.pbf>` and `upload`, and the
   four sets of squares (*Building the squares*).
2. `Scripts/vector-archives.sh basemap` copies Protomaps' newest daily
   build of the schema the app reads into the bucket.
3. `Scripts/vector-archives.sh use` with each new name, then `publish`, and
   commit the manifest.
4. `Scripts/offline-countries.sh publish` cuts every area again from the
   new archives and puts it up.
5. `prune` in `Scripts/vector-archives.sh` and
   `Scripts/offline-countries.sh`, once the apps have read the new
   manifests. An archive leaves the manifest before it leaves the bucket.
   `Scripts/trail-cells.sh prune` is no part of a refresh: it takes the
   public database's copies from 1.5–1.7 (*The public database's copies of
   the squares*).

### Building the squares

`Scripts/trail-cells.sh` builds and publishes all four sets, and its header
has every option:

1. `update-planet <planet.osm.pbf>`. The planet is downloaded once and then
   kept current with the hourly changes openstreetmap.org publishes,
   because the volunteers who serve it asked that it not be downloaded
   again for each refresh.
2. `build <planet.osm.pbf> --world`, `build-routes`, `build-places` and
   `build-routing`, each with `--world`.
3. `pack <dir>` for the first three; `build-routing` writes its archive
   itself.
4. `upload-archive <dir>` for all four, then `Scripts/vector-archives.sh
   use` with each name, `publish`, and commit the manifest.

### Building the elevation squares

The heights are no part of a refresh. They change only with a new release of
the Copernicus DEM, or a new generation of `ElevationSquareFile`, and an
archive of them stays listed until then (*The elevation squares* in
`AGENTS.md`).

1. `Scripts/trail-cells.sh build-elevation --out <dir>` reads every tile of
   Copernicus' public bucket and writes the whole world. Its header has the
   time and the size it measured.
2. `upload-archive <dir>`, then `Scripts/vector-archives.sh use <name>`
   (with `--generation 1` for the list's first archive), `publish`, and
   commit the manifest.
3. The areas take the new heights with their next build, which
   `Scripts/offline-countries.sh publish` cuts from the first `elevation`
   archive the manifest names. A build already up that has none gains them
   through `Scripts/offline-countries.sh elevation`, then `upload`; one that
   has them keeps them, because an upload never replaces a file's bytes.

### The public database's copies of the squares

Builds v1.5-1 to v1.7-1 read the squares as `CuratedTrailCell` records, under
the same names (*Persisted identifiers* in `AGENTS.md`), and nothing later
does. `Scripts/trail-cells.sh upload` refreshes them, and `prune` takes a set
down once those builds are gone: it marks the set's manifest incomplete first,
so they fall back to Overpass, deletes the squares, and deletes the manifest
record last, because it is the only list of them. Both record types were added
by schema import before the first upload, for the reason *A new field arrives
indexed* in `AGENTS.md` gives.

### Tile server deployment state

Checked 2026-11-24. The bucket holds every area of build `20261124`, cut from
`planet-20261124` and `extras-20261124-16`, with its day hikes from
`trails-20261124-16` 50 km round it: 381 of them (234 countries, and the 51
states, 13 provinces and 83 regions of the three split ones), 1,905 files and
181.0 GB, of which the day hikes are 279 MB, and no other country file.
Beside them it holds those two archives, the five sets of squares, and the
manifest at revision 13, which names all seven, and nothing else. The squares
are `routing-20261124-16`, `trails-20261124-16`, `routes-20261124-16` and
`places-20261124-16`, each the planet of 2026-11-24 16:00 UTC, and the heights
`elevation-20261126-20` (66.4 GB, added 2026-11-27 with revision 13), the
Copernicus DEM as the AWS bucket held it on 2026-11-26.

## Simulators and the Mac

### The iPhone Duo

- **It needs a runtime of its own, which runs no other device:** iOS 27.1 as
  Xcode 27.1 installed it, and a build of iOS 27.2 for the Duo alone under
  Xcode 27.2. CI's Xcode 27.0 has neither, so no gate runs on a Duo, and the
  27.1 SDK's Duo APIs do not exist where CI compiles (*CI* in `AGENTS.md`
  has the gate). Templates and the pool pick the newest runtime that runs
  their device type, never just the newest.
- **It boots closed**, on the cover display (466 × 678 points).
  `Scripts/duo-pose.sh open --device <udid>` unfolds it to the inner display
  (669 × 951, upright) and reads the display state back.
  `--orientation landscape` leaves it 951 × 669, wide enough for the map
  screen's side panel.
- **Opening it takes hinge**
  ([artemnovichkov/hinge](https://github.com/artemnovichkov/hinge)), an
  optional Homebrew tool. Give it the pool device every time (`-d "$udid"`):
  without `-d` it folds the only booted iPhone Duo, which on a shared machine
  can be another session's.
- **XCTest sees it through the cover.** `XCUIScreen.main` is the cover display
  open or closed, and on the inner display turned sideways `app.frame` stays
  portrait while `app.windows.firstMatch.frame` turns. There `isHittable` also
  answers no for everything in the side panel, so the shared helpers measure
  the window and skip it (`OpenHikesUITests/WindowSupport.swift`).

### Running the Mac build outside Xcode

Build with `-destination 'platform=macOS,arch=arm64,variant=Designed for
iPad'`, put the `Debug-iphoneos` app inside a wrapper
(`X.app/Wrapper/OpenHikes.app`, with an `X.app/WrappedBundle` symlink to it)
and `open` the wrapper. What a Mac build must keep is *The Mac* in
`AGENTS.md`.
