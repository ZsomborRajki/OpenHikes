//
//  PrivacyManifestTests.swift
//  OpenHikesTests
//
//  What the shipping privacy manifest says, held against what the app does.
//
//  `PrivacyInfo.xcprivacy` is part of the upload rather than documentation,
//  and it is the one file in the tree that nothing else in the tree can
//  contradict out loud. A field added to a submission, a new identifier kept
//  for moderation, a required-reason API reached for in a refactor — none of
//  those touch this file, and none of them fail a build. The rejection arrives
//  from App Store Connect, long afterwards, naming an API rather than the
//  manifest; or worse, it does not arrive at all and the app ships a
//  declaration that is no longer true.
//
//  That is what these are for. They read the manifest out of the built bundle
//  — the copy that actually ships, not a path in the repository — and assert
//  the shape of what it declares. They cannot know whether a declaration is
//  *right*; that argument lives in the manifest's own comments and in
//  `docs/terms/`. What they can do is make a silent removal loud, and make
//  anybody adding a collected type say so here as well.
//
//  The User ID and Fitness entries are the reason this file exists. Both were
//  missing while the code they describe was already shipping: CloudKit's
//  creator ID has been copied onto every published listing and used to block
//  an author since Community was written, and a published route has always
//  carried the timestamps that make it a workout as well as a place.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Privacy manifest")
struct PrivacyManifestTests {
    /// The manifest as it is bundled, which is the only copy that means
    /// anything: a file in the repository that failed to be copied into the
    /// app would pass every assertion below while shipping nothing.
    private func manifest() throws -> [String: Any] {
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the app bundle carries no privacy manifest"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
        return try #require(plist as? [String: Any])
    }

    private func collectedTypes() throws -> [[String: Any]] {
        let entries = try manifest()["NSPrivacyCollectedDataTypes"]
        return try #require(entries as? [[String: Any]])
    }

    private func entry(for type: String) throws -> [String: Any] {
        let match = try collectedTypes().first { $0["NSPrivacyCollectedDataType"] as? String == type }
        return try #require(match, "\(type) is not declared")
    }

    /// Everything this app sends to the public database, and nothing it does
    /// not. An exact set rather than a subset: a type quietly dropped is the
    /// failure this file exists to catch, and a type quietly added is a change
    /// to what the App Store listing has to answer.
    @Test("the manifest declares exactly what sharing a hike sends")
    func everySharedTypeIsDeclared() throws {
        let declared = try collectedTypes().compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        #expect(
            Set(declared) == [
                "NSPrivacyCollectedDataTypeFitness",
                "NSPrivacyCollectedDataTypeOtherUserContent",
                "NSPrivacyCollectedDataTypePhotosorVideos",
                "NSPrivacyCollectedDataTypePreciseLocation",
                "NSPrivacyCollectedDataTypeUserID",
            ]
        )
        #expect(declared.count == Set(declared).count, "a type is declared twice")
    }

    /// The identifier the app keeps on purpose. CloudKit stamps a submission
    /// with its creator, the reviewer copies that onto the listing as
    /// `authorID`, and `CloudKitCommunityTransport` refuses a listing without
    /// one — so it is what blocking and taking down a hike both act on.
    ///
    /// It was argued for in the manifest's own comment and declared nowhere,
    /// which is the wrong way round and is what this pins.
    @Test("the creator identifier is declared")
    func theUserIdentifierIsDeclared() throws {
        let userID = try entry(for: "NSPrivacyCollectedDataTypeUserID")
        #expect(userID["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(userID["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
    }

    /// The walk as exercise. Every point of a published route carries its
    /// timestamp, so the duration and the pace go up with the line, and the
    /// preview draws them straight back out.
    @Test("the walk's timing is declared as fitness data")
    func fitnessIsDeclared() throws {
        let fitness = try entry(for: "NSPrivacyCollectedDataTypeFitness")
        #expect(fitness["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(fitness["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
    }

    /// Linked, and honestly so: a submission carries a name and a creator ID,
    /// which is exactly what makes reviewing and taking one down possible.
    /// Claiming otherwise about any one of these would be claiming the
    /// moderation the App Store requires does not work.
    @Test("every collected type is linked to the user and used for app functionality")
    func everyTypeIsLinkedAndPurposed() throws {
        for type in try collectedTypes() {
            let name = type["NSPrivacyCollectedDataType"] as? String ?? "an unnamed type"
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true, "\(name) is not linked")
            #expect(
                type["NSPrivacyCollectedDataTypePurposes"] as? [String]
                    == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                "\(name) declares a purpose other than app functionality"
            )
        }
    }

    /// Nothing here is joined with data from other companies' apps or sites,
    /// and nothing in the app contacts a domain that would make it possible.
    /// The flag and the empty array have to agree, because App Store Connect
    /// asks the question separately from the manifest.
    @Test("nothing is declared for tracking")
    func nothingTracks() throws {
        let manifest = try manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let domains = try #require(manifest["NSPrivacyTrackingDomains"] as? [String])
        #expect(domains.isEmpty)
        for type in try collectedTypes() {
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        }
    }

    /// The four required-reason codes the app's own APIs oblige it to declare.
    /// An upload missing one is rejected with ITMS-91053, and the rejection
    /// names the API rather than the manifest — so reaching for a new one
    /// means adding its code, and dropping one here means this fails first.
    @Test("every required-reason API keeps its code")
    func requiredReasonAPIsAreDeclared() throws {
        let accessed = try #require(
            manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        var reasons: [String: [String]] = [:]
        for api in accessed {
            guard let type = api["NSPrivacyAccessedAPIType"] as? String else { continue }
            reasons[type] = api["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }

        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "3B52.1"])
        #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
    }
}
