# OpenTrails Code Review

Original review: 2026-08-11 at commit `2ee19ea`. Status updated against the working tree based on `7b24824` (`main`).

## Executive summary

The app remains structurally sound, and the infrastructure the previous review called out as its outstanding risk is now built: the tile pipeline, the background-relaunch path and the widget all have injectable seams, and the suites that used to share process-global singletons own their own state.

No current finding is a crash or data-loss defect, and no measured per-event cost remains.

What is left is CI. The state below is local and unprotected on pull requests.

## Current build and test state

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator |
| iOS app tests | Pass | **372 tests, 42 suites**, 0 known issues, 0 skipped |
| Widget tests | Pass | **14 tests, 2 suites** |
| Shared package tests | Pass | 43 tests, 5 suites |
| macOS build | Pass | Unsigned, arm64 |
| visionOS build | **Not verified** | No visionOS runtime installed on this machine |
| iPadOS | **Not verified** | No iPad simulator installed |
| CI | **Absent** | `.github/workflows` does not exist |

## Test gaps

One remains, and it is a property of the environment rather than of the suite.

**Conditional suites can still vanish silently.** `WidgetFeedSuites` and the widget target's `Trail widget` suite disable entirely without the App Group container. Both now report the skip, and strict mode turns it into a failure:

```sh
xcodebuild test … "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"
```

Nothing passes that yet, because nothing runs the tests except a person. It becomes real coverage the moment CI does.

## Repository hygiene

- **No CI.** `.github/workflows` does not exist. The passing state above is local and unprotected on pull requests; cross-platform compile failures have reached `main` before. Add compile gates for iOS, macOS, and visionOS plus all three test suites, run them in strict mode (see above) so a suite that can't run fails rather than disappearing.
- **No localization catalog.** All user-facing strings are in source — fine for a single-language prototype, a product-readiness task before localization.

## TODO

### Infrastructure

- [ ] **Add CI** (hygiene): compile gates for iOS, macOS and visionOS; the app, widget and shared-package test suites; strict mode, so a suite that can't run fails instead of disappearing.

### Product readiness

- [ ] **Add a localization catalog** before the app is offered in more than one language.
