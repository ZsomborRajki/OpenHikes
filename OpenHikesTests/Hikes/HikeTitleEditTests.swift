//
//  HikeTitleEditTests.swift
//  OpenHikesTests
//
//  What a name typed into a field means for the hike behind it.
//
//  The rule has three answers and only one of them is obvious. Typing a new
//  name renames the hike; that is the case everybody thinks of. The other two
//  are the ones a `View` would get wrong silently:
//
//  *Untouched* must write nothing. The share form seeds its field from
//  ``Hike/displayTitle``, which falls back to ``Hike/title`` when there is no
//  custom name — so writing the field back naively would turn a hike's own
//  title into a `customName` that merely matches it. Nothing on screen would
//  change, and the column is mirrored, so the cost is a CloudKit write for a
//  rename nobody made.
//
//  *Emptied* must write `nil`, not `""`. Clearing the box means "go back to
//  what this hike was called", and only `nil` says that — an empty string is a
//  custom name that happens to be blank, which ``Hike/displayTitle`` then has
//  to special-case forever.
//
//  Which is why this is a type rather than four lines inside the sheet: a
//  suite can ask a type whether leaving a field alone writes to the store, and
//  cannot ask a `View` anything at all.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike title edit")
struct HikeTitleEditTests {
    @Test("a new name renames the hike")
    func aNewNameRenames() {
        #expect(
            HikeTitleEdit.of("Thumsee Ridge", against: "Morning walk")
                == .renamed("Thumsee Ridge")
        )
    }

    /// The case that costs a mirrored write if it is got wrong, and shows
    /// nothing at all if it is.
    @Test("text nobody touched writes nothing")
    func untouchedTextWritesNothing() {
        #expect(HikeTitleEdit.of("Morning walk", against: "Morning walk") == .unchanged)
    }

    /// Trimmed before comparing, so a stray space picked up by a keyboard is
    /// not a rename either.
    @Test("whitespace around an unchanged name is still unchanged")
    func paddedTextIsStillUnchanged() {
        #expect(HikeTitleEdit.of("  Morning walk  ", against: "Morning walk") == .unchanged)
    }

    /// Clearing the field restores the hike's own title, which is `nil` on the
    /// custom name rather than an empty string in it.
    @Test("an emptied field takes the custom name off")
    func emptyFieldClearsTheCustomName() {
        #expect(HikeTitleEdit.of("", against: "Morning walk") == .renamed(nil))
        #expect(HikeTitleEdit.of("   ", against: "Morning walk") == .renamed(nil))
    }

    /// A hike that has no name at all is the one case where an empty field is
    /// *unchanged* rather than a clearing — there is nothing to take off.
    @Test("emptying a hike that was never named writes nothing")
    func emptyFieldOnAnUnnamedHikeWritesNothing() {
        #expect(HikeTitleEdit.of("", against: "") == .unchanged)
    }

    /// The bound is ``HikeTitle``'s, applied here because this is a name
    /// entering the app the way the rename field and the importer are — see
    /// *A hike's name is bounded where it is entered* in the repository
    /// instructions.
    @Test("a name entered here is bounded like every other")
    func longNamesAreBounded() {
        let overlong = String(repeating: "a", count: HikeTitle.maximumCharacters + 50)

        guard case .renamed(let name) = HikeTitleEdit.of(overlong, against: "Morning walk") else {
            Issue.record("an overlong name is still a rename")
            return
        }

        #expect(name?.count == HikeTitle.maximumCharacters)
    }

    /// A grapheme cluster has no length limit, which is why the byte bound
    /// exists beside the character one. The point here is only that this entry
    /// point gets both, since it goes through the same function.
    @Test("a name that is one enormous character is bounded too")
    func combiningMarksAreBounded() {
        let single = "a" + String(repeating: "\u{0301}", count: 5000)

        guard case .renamed(let name) = HikeTitleEdit.of(single, against: "Morning walk") else {
            Issue.record("an overlong name is still a rename")
            return
        }

        #expect((name?.utf8.count ?? 0) <= HikeTitle.maximumUTF8Bytes)
    }
}
