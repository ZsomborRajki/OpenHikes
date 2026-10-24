//
//  CreationTipsAudienceTests.swift
//  OpenHikesTests
//
//  Who the two tips about making a hike are for — see
//  ``CreationTipsAudience``. The owner's rule is that an existing hiker is
//  never told how to make a hike; the case that made this a decision rather
//  than a count is the new hiker who does what *Record a Hike* says, and whose
//  recording once retired *Make a Trail* before it was ever drawn.
//
//  A value walked by hand, with the answers ``AppTips`` acts on. Nothing here
//  reaches TipKit's store — see ``TipLaunch``.
//

@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Who the tips about making a hike are for")
struct CreationTipsAudienceTests {
    @Test("an empty list is shown the two, and a list not yet loaded is not")
    func anEmptyListIsShownThem() {
        var audience = CreationTipsAudience(isNewHiker: false)
        #expect(!audience.wantsTips, "a list not yet loaded could be an existing hiker's")

        let retired = audience.libraryDidLoad(holdsAHike: false)

        #expect(!retired)
        #expect(audience.wantsTips)
    }

    /// The owner's rule, on the launch that first has tips: a hike already in
    /// the list retires both at once, so the queue moves on to the
    /// *Community* tab's.
    @Test("an existing hiker's list retires the two at once")
    func anExistingHikerRetiresThem() {
        var audience = CreationTipsAudience(isNewHiker: false)

        let retired = audience.libraryDidLoad(holdsAHike: true)

        #expect(retired)
        #expect(!audience.wantsTips)
    }

    /// The review's walk: *Record a Hike* is drawn over the pill, the hiker
    /// taps Record, and saves. Their first hike is the tip working, not the
    /// evidence of an existing hiker, so *Make a Trail* still gets its turn.
    @Test("a hike begun from the pill on an empty list retires neither")
    func aFirstHikeFromThePillKeepsThem() {
        var audience = CreationTipsAudience(isNewHiker: false)
        _ = audience.libraryDidLoad(holdsAHike: false)

        let becameNew = audience.pillUsed()
        let retired = audience.libraryDidLoad(holdsAHike: true)

        #expect(becameNew, "the first tap on an empty list is the one to keep")
        #expect(!retired)
        #expect(audience.wantsTips)
    }

    /// Kept in TipKit's store and handed back, so a relaunch after that first
    /// hike decides nothing again.
    @Test("a new hiker stays one on a later launch")
    func aNewHikerIsDecidedOnce() {
        var audience = CreationTipsAudience(isNewHiker: true)
        #expect(audience.wantsTips, "a new hiker's list need not load first")

        let retired = audience.libraryDidLoad(holdsAHike: true)
        let becameNew = audience.pillUsed()

        #expect(!retired)
        #expect(audience.wantsTips)
        #expect(!becameNew, "nothing more to keep")
    }

    /// A list not yet loaded could be an existing hiker's, and one with a hike
    /// in it has already retired the two.
    @Test("the pill makes a new hiker only on a list known to be empty")
    func onlyAnEmptyListMakesANewHiker() {
        var unloaded = CreationTipsAudience(isNewHiker: false)
        var existing = CreationTipsAudience(isNewHiker: false)
        _ = existing.libraryDidLoad(holdsAHike: true)

        let unloadedBecameNew = unloaded.pillUsed()
        let existingBecameNew = existing.pillUsed()

        #expect(!unloadedBecameNew)
        #expect(!existingBecameNew)
        #expect(!existing.wantsTips)
    }

    /// An import, a walk from the watch or a recording started by Siri, before
    /// the pill was ever used: a hike in the list is still the evidence the
    /// owner's rule goes by.
    @Test("a hike that arrives before the pill is used retires the two")
    func aHikeFromElsewhereRetiresThem() {
        var audience = CreationTipsAudience(isNewHiker: false)
        _ = audience.libraryDidLoad(holdsAHike: false)

        let retired = audience.libraryDidLoad(holdsAHike: true)

        #expect(retired)
        #expect(!audience.wantsTips)
    }

    @Test("a report that changes nothing retires nothing again")
    func aRepeatedReportIsIgnored() {
        var audience = CreationTipsAudience(isNewHiker: false)
        _ = audience.libraryDidLoad(holdsAHike: true)

        let retiredAgain = audience.libraryDidLoad(holdsAHike: true)

        #expect(!retiredAgain)
    }

    /// The draft a recording inserts the moment it starts is a real row with
    /// `isRecording` set. Counted, a Record started from Siri and then
    /// discarded left an empty list with both tips retired for good.
    @Test("a recording in progress is not a hike in the list")
    func aRecordingDraftIsNotAHike() throws {
        let context = try Fixture.modelContext()
        let draft = Fixture.hike(in: context, title: "Recording") { $0.isRecording = true }
        let finished = Fixture.hike(in: context)

        #expect(!CreationTipsAudience.holdsAHike([]))
        #expect(!CreationTipsAudience.holdsAHike([draft]))
        #expect(CreationTipsAudience.holdsAHike([draft, finished]))
    }
}
