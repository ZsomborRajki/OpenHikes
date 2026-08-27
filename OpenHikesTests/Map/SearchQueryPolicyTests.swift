//
//  SearchQueryPolicyTests.swift
//  OpenHikesTests
//
//  `SearchCompleter` itself is three lines of MapKit plumbing around this
//  type, and none of those three can be held to anything: the completer has
//  no stub, `MKLocalSearchCompletion` has no public initializer, and a
//  request that was never made looks exactly like one that hasn't answered
//  yet. The decision is the part with behaviour, so it is the part asserted.
//
//  Two of the cases below are the reason it exists at all. The echo case
//  stops a wasted network round-trip every time a suggestion is tapped; the
//  cancel case stops an answer for a question the user has withdrawn from
//  refilling the list under a search field they have just emptied.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Search query policy")
struct SearchQueryPolicyTests {
    @Test("a fragment the user is typing is asked for")
    func typingRequests() {
        var policy = SearchQueryPolicy()

        #expect(policy.action(for: "Zug") == .request("Zug"))
    }

    /// The field's text arrives with whatever the keyboard left on it, and a
    /// trailing space is not a different question.
    @Test("a query is asked for in its trimmed form", arguments: ["  Zugspitze", "Zugspitze  ", "\nZugspitze\t"])
    func queriesAreTrimmed(raw: String) {
        var policy = SearchQueryPolicy()

        #expect(policy.action(for: raw) == .request("Zugspitze"))
    }

    /// Emptying the field has to stop the completer, not merely blank the
    /// list: a request already in flight would otherwise answer into an empty
    /// search field and put the suggestions back.
    @Test("emptying the field cancels the request behind it", arguments: ["", "   ", "\n\t "])
    func emptyingCancels(raw: String) {
        var policy = SearchQueryPolicy()
        _ = policy.action(for: "Zugspitze")

        #expect(policy.action(for: raw) == .cancel)
    }

    /// Tapping a suggestion writes its title into the field, which fires the
    /// field's `onChange` with text the completer has already answered.
    @Test("the echo of a tapped suggestion is not asked for again")
    func committedQueryIsIgnored() {
        var policy = SearchQueryPolicy()
        policy.commit(query: "Zugspitze, Garmisch")

        #expect(policy.action(for: "Zugspitze, Garmisch") == .ignore)
    }

    /// The echo arrives through the same trimming as everything else, so a
    /// commit that was trimmed and an echo that wasn't still have to match.
    @Test("the echo is recognised through the trimming")
    func committedQueryIsMatchedTrimmed() {
        var policy = SearchQueryPolicy()
        policy.commit(query: "  Zugspitze  ")

        #expect(policy.action(for: "Zugspitze") == .ignore)
        #expect(policy.committedQuery == "Zugspitze")
    }

    /// One echo, not a permanent block: the user carries on typing after
    /// tapping a suggestion, and the very next keystroke is a new question.
    @Test("typing on after a commit asks again")
    func typingAfterCommitRequests() {
        var policy = SearchQueryPolicy()
        policy.commit(query: "Zugspitze")
        #expect(policy.action(for: "Zugspitze") == .ignore)

        #expect(policy.action(for: "Zugspitze N") == .request("Zugspitze N"))
        // …and the commit is spent, so returning to the committed text is a
        // question again rather than a second echo.
        #expect(policy.committedQuery == nil)
        #expect(policy.action(for: "Zugspitze") == .request("Zugspitze"))
    }

    /// Backspacing to empty spends the commit too, so retyping the same place
    /// name from scratch is answered rather than silently ignored.
    @Test("emptying the field spends the commit")
    func emptyingForgetsTheCommit() {
        var policy = SearchQueryPolicy()
        policy.commit(query: "Zugspitze")

        #expect(policy.action(for: "") == .cancel)
        #expect(policy.committedQuery == nil)
        #expect(policy.action(for: "Zugspitze") == .request("Zugspitze"))
    }

    @Test("clearing forgets the commit as well")
    func resetForgetsTheCommit() {
        var policy = SearchQueryPolicy()
        policy.commit(query: "Zugspitze")

        policy.reset()

        #expect(policy.committedQuery == nil)
        #expect(policy.action(for: "Zugspitze") == .request("Zugspitze"))
    }

    /// The same fragment twice is still asked twice. `MKLocalSearchCompleter`
    /// is what de-duplicates an unchanged `queryFragment`, and the policy
    /// deliberately does not second-guess it — only the commit suppresses.
    @Test("an unchanged fragment is left for the completer to de-duplicate")
    func repeatedFragmentsAreStillRequested() {
        var policy = SearchQueryPolicy()

        #expect(policy.action(for: "Zug") == .request("Zug"))
        #expect(policy.action(for: "Zug") == .request("Zug"))
    }

    /// A fresh policy has nothing committed, so the first thing typed after
    /// launch is never mistaken for an echo.
    @Test("a new policy has committed to nothing")
    func startsUncommitted() {
        let policy = SearchQueryPolicy()

        #expect(policy.committedQuery == nil)
    }
}
