//
//  InfoPlistContractTests.swift
//  OpenHikesTests
//
//  The bundle keys whose absence is silent.
//
//  Three bundle-level contracts already had a test that reads `Bundle.main` —
//  `GPXDocumentTypeTests` for the document declarations, `PrivacyManifestTests`
//  for the collected types, `TileUserAgentTests` for the header. The keys below
//  are the ones nobody had got to, and they are the ones that fail *quietly*:
//  every one is a string in a plist or a build setting, none is referenced by
//  any Swift symbol, and each failure looks like a feature that was never
//  built rather than a key that went missing.
//
//  | Key | What its absence does |
//  |---|---|
//  | `NSSupportsLiveActivities` | `Activity.request` throws; nothing appears |
//  | `UIBackgroundModes` → `location` | a recording stops when the phone is pocketed |
//  | `UIBackgroundModes` → `remote-notification` | CloudKit pushes stop arriving |
//  | `NSLocationTemporaryUsageDescriptionDictionary` → `RecordHike` | full accuracy is never granted |
//  | `NSLocationWhenInUseUsageDescription` | the authorization prompt never appears |
//  | `NSLocationAlwaysAndWhenInUseUsageDescription` | Background Trail Tracking cannot be granted |
//  | `NSMotionUsageDescription` | barometric fusion and motion state fail |
//  | `NSCameraUsageDescription` | in-hike capture fails |
//  | `NSPhotoLibraryUsageDescription` / `…AddUsageDescription` | the photo features fail |
//
//  Two things make this more than theoretical.
//
//  **Nothing else lists the permission strings in one place.** This does, and
//  it reads the *merged* dictionary the build produces rather than the file —
//  a string can reach the bundle from `OpenHikes/Info.plist` or from an
//  `INFOPLIST_KEY_…` build setting, and the merged dictionary is where the two
//  halves meet. They all live in the plist today, which is also the one of the
//  two a reviewer of a diff can see: `GENERATE_INFOPLIST_FILE` is `NO` here
//  (an Xcode 27 crash workaround — see the repository instructions), so an
//  `INFOPLIST_KEY_…` setting added back would be inert, and reading the
//  bundle is what would say so.
//
//  **`RecordHike` is a matched pair of string literals** — a plist dictionary
//  key and an argument at the call site. It is asserted against
//  ``LocationPurposeKey/recordHike``, the constant the recorder actually
//  passes, rather than against the same spelling written out again: a test
//  that restated the literal would agree with itself no matter which half was
//  renamed.
//
//  This covers the class of breakage an archive check cannot: the archive job
//  verifies what the bundle does *not* carry, and nothing verified what it
//  must.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Info.plist contract")
struct InfoPlistContractTests {
    /// Read from `Bundle.main` rather than from a file in the repository, for
    /// the reason `PrivacyManifestTests` gives: a key that failed to reach the
    /// built product would pass every assertion below while shipping nothing.
    /// It is also the only place the plist and the `INFOPLIST_KEY_…` build
    /// settings are visible together.
    private func string(_ key: String) throws -> String {
        try #require(
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
            "\(key) is missing from the built bundle"
        )
    }

    // MARK: - The permission strings a hiker reads

    /// Non-empty as well as present: iOS shows the string verbatim in the
    /// prompt, and an empty one is a prompt that asks for location and gives
    /// no reason — which is a rejection as reliably as a missing key is a
    /// broken feature.
    ///
    /// All of them are in `OpenHikes/Info.plist`, and the merged dictionary is
    /// read anyway — see this file's header for why the source of a string is
    /// not something this test should have an opinion about.
    @Test("every usage description the app can trigger is present and says something", arguments: [
        "NSLocationWhenInUseUsageDescription",
        "NSLocationAlwaysAndWhenInUseUsageDescription",
        "NSMotionUsageDescription",
        "NSCameraUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
    ])
    func usageDescriptionIsPresent(key: String) throws {
        let description = try string(key)
        #expect(!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The pair that is a rename away from silence.
    ///
    /// `withPurposeKey:` takes a string and Core Location does not complain
    /// about one it cannot find; the request simply fails and the recording
    /// runs at reduced accuracy for the rest of the walk.
    @Test("the temporary full-accuracy key matches the one the recorder asks for")
    func temporaryAccuracyPurposeKeyMatches() throws {
        let dictionary = try #require(
            Bundle.main.object(
                forInfoDictionaryKey: "NSLocationTemporaryUsageDescriptionDictionary"
            ) as? [String: String],
            "NSLocationTemporaryUsageDescriptionDictionary is missing from the built bundle"
        )
        let purpose = try #require(
            dictionary[LocationPurposeKey.recordHike],
            """
            the recorder asks for "\(LocationPurposeKey.recordHike)" and the plist \
            declares \(dictionary.keys.sorted())
            """
        )
        #expect(!purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - The version a hiker reads off the screen

    /// Both keys are generated by Xcode from `MARKETING_VERSION` and
    /// `CURRENT_PROJECT_VERSION`, so neither can be edited away by hand — but
    /// both can be renamed or dropped by a target that stops inheriting them,
    /// and `AboutSection` would then draw an empty *Version* row rather than
    /// fail. That is the same class of silence every other key in this file is
    /// here for.
    ///
    /// It matters more than a blank row looks: #340 makes an archived build
    /// tagged `v<marketing>-<build>`, so these two strings are the only thing
    /// that turns a crash report or a bug report into a revision.
    @Test("the bundle says which version and build it is", arguments: [
        "CFBundleShortVersionString",
        "CFBundleVersion",
    ])
    func versionKeyIsPresent(key: String) throws {
        let value = try string(key)
        #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// What the settings row actually draws. Asserted against the bundle
    /// rather than against a second copy of the format string: a test that
    /// restated "1.0 (26)" would agree with itself while the screen drew
    /// something else.
    @Test("the settings row reads both of them back")
    func versionRowReadsTheBundle() throws {
        let marketing = try string("CFBundleShortVersionString")
        let build = try string("CFBundleVersion")

        #expect(AppVersion.marketing == marketing)
        #expect(AppVersion.build == build)
        #expect(AppVersion.display == "\(marketing) (\(build))")
        #expect(AppVersion.display.contains(marketing))
    }

    /// The tile and Overpass User-Agent reads the same value, and both
    /// policies ask that the header identify the application — so the two must
    /// not drift into separate readings of the same key.
    @Test("the User-Agent announces the same version the settings row shows")
    func userAgentUsesTheSameVersion() {
        #expect(TileCache.userAgent.contains("OpenHikes/\(AppVersion.marketing)"))
    }

    // MARK: - The capabilities nothing in Swift refers to

    /// Without this ActivityKit reports activities disabled and
    /// `Activity.request` throws, with nothing in the UI to say why — which
    /// the plist's own comment already spells out, and which nothing checked.
    @Test("Live Activities are declared")
    func liveActivitiesAreDeclared() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true
        )
    }

    /// Deliberately *absent*, and worth pinning as an absence: the app updates
    /// on a twenty-second throttle of its own, so asking for the
    /// frequent-update allowance would be claiming a budget it does not use.
    /// A future change that sets it should have to argue here first.
    @Test("the frequent-update allowance is not claimed")
    func frequentUpdatesAreNotClaimed() {
        #expect(
            Bundle.main.object(
                forInfoDictionaryKey: "NSSupportsLiveActivitiesFrequentUpdates"
            ) == nil
        )
    }

    /// Both modes, and an exact set. `location` is what keeps a recording
    /// running with the phone in a pocket; `remote-notification` is what lets
    /// CloudKit pushes arrive. A mode added here is a mode App Review asks
    /// about, so this fails on an addition as well as on a loss.
    @Test("the background modes are exactly the two the app uses")
    func backgroundModesAreDeclared() throws {
        let modes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
            "UIBackgroundModes is missing from the built bundle"
        )
        #expect(Set(modes) == ["location", "remote-notification"])
    }

    /// Not a permission, but the same shape of silent failure: without it App
    /// Store Connect prompts for an export compliance questionnaire on every
    /// upload, and the answer is always the same one.
    @Test("the export compliance answer is declared")
    func exportComplianceIsDeclared() {
        #expect(
            Bundle.main.object(
                forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption"
            ) as? Bool == false
        )
    }
}
