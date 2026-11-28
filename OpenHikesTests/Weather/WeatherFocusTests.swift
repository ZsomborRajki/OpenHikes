//
//  WeatherFocusTests.swift
//  OpenHikesTests
//
//  Who owns the weather badge.
//
//  Four call sites can point it somewhere — the recorder, hike selection,
//  search and the map's location button — and the rule between them is not
//  obvious enough to be left to the call sites: an active recording owns the
//  subject outright, so a search made mid-hike moves the map and leaves the
//  badge alone. That rule is the whole reason ``WeatherFocus`` is a type
//  rather than a property, and it is what these assert.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Weather focus")
struct WeatherFocusTests {
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)
    /// About 3 km from ``budapest`` — inside the trail-follow radius.
    private let nearBudapest = CLLocationCoordinate2D(latitude: 47.5250, longitude: 19.0402)

    private func trail(at coordinate: CLLocationCoordinate2D, name: String = "Pilis Loop") -> WeatherSubject {
        .trail(coordinate, hikeID: UUID(), name: name)
    }

    @Test("nothing is focused until something focuses it")
    func startsEmpty() {
        #expect(WeatherFocus().subject == nil)
    }

    @Test("a search points the badge at the searched place")
    func searchFocuses() {
        let focus = WeatherFocus()
        focus.focus(on: .place(budapest, name: "Budapest"))
        #expect(focus.subject == .place(budapest, name: "Budapest"))
    }

    /// The precedence rule, stated directly. A hiker mid-hike who searches
    /// for a city is asking the *map* to go there; the badge is the one thing
    /// on screen still answering "what am I standing in".
    @Test("a recording owns the badge, and a search cannot take it")
    func recordingOutranksSearch() {
        let focus = WeatherFocus()
        focus.pinToHiker(at: budapest)

        focus.focus(on: .place(vienna, name: "Vienna"))

        #expect(focus.subject == .me(budapest))
        #expect(focus.isPinnedToHiker)
    }

    @Test("a recording outranks a hike selection too")
    func recordingOutranksSelection() {
        let focus = WeatherFocus()
        focus.pinToHiker(at: budapest)

        focus.focus(on: trail(at: vienna))

        #expect(focus.subject == .me(budapest))
    }

    /// Releasing the pin must not blank the badge, and must not hand it back
    /// to a search the hiker made before they set off. "Here" is still the
    /// right answer the moment a recording ends.
    @Test("ending a recording keeps the subject where it is")
    func unpinningKeepsTheSubject() {
        let focus = WeatherFocus()
        focus.focus(on: .place(vienna, name: "Vienna"))
        focus.pinToHiker(at: budapest)

        focus.unpinFromHiker()

        #expect(focus.subject == .me(budapest))
        #expect(!focus.isPinnedToHiker)
    }

    @Test("once the recording ends a search wins again")
    func searchWinsAfterUnpinning() {
        let focus = WeatherFocus()
        focus.pinToHiker(at: budapest)
        focus.unpinFromHiker()

        focus.focus(on: .place(vienna, name: "Vienna"))

        #expect(focus.subject == .place(vienna, name: "Vienna"))
    }

    @Test("the hiker moving moves a `me` subject with them")
    func movementMovesTheHiker() {
        let focus = WeatherFocus()
        focus.pinToHiker(at: budapest)

        focus.hikerMoved(to: vienna)

        #expect(focus.subject == .me(vienna))
    }

    @Test("a recording claims ownership before its first fix")
    func recordingWithoutLocationOwnsTheNextFix() {
        let focus = WeatherFocus(subject: .place(vienna, name: "Vienna"))
        focus.pinToHiker(at: nil)
        focus.focus(on: .place(budapest, name: "Budapest"))
        focus.focus(on: trail(at: budapest))

        #expect(focus.isPinnedToHiker)
        #expect(focus.subject == nil)
        #expect(focus.hikerMoved(to: vienna))
        #expect(focus.subject == .me(vienna))
    }

    @Test("only movement that changes the forecast subject merits a movement request")
    func irrelevantMovementDoesNotRequest() {
        let place = WeatherSubject.place(budapest, name: "Budapest")
        let selected = trail(at: budapest)
        for subject in [place, selected, .me(vienna)] {
            let focus = WeatherFocus(subject: subject)
            #expect(!focus.hikerMoved(to: vienna))
            #expect(focus.subject == subject)
        }

        let nearbyTrail = WeatherFocus(subject: selected)
        #expect(nearbyTrail.hikerMoved(to: nearBudapest))
        let hiker = WeatherFocus(subject: .me(budapest))
        #expect(hiker.hikerMoved(to: vienna))
        let empty = WeatherFocus()
        #expect(empty.hikerMoved(to: vienna))
        #expect(empty.subject == .me(vienna))
    }

    /// The second half of "I start hiking on that imported trail": a hiker
    /// who is out on the route they selected should get the weather where they
    /// are, not where the file's midpoint happens to be.
    @Test("a selected trail follows the hiker once they are on it")
    func trailFollowsAHikerNearby() {
        let focus = WeatherFocus()
        let selected = trail(at: budapest)
        focus.focus(on: selected)

        focus.hikerMoved(to: nearBudapest)

        #expect(focus.subject?.coordinate.latitude == nearBudapest.latitude)
        #expect(focus.subject?.placeName == "Pilis Loop", "still the same trail, and still named")
    }

    /// And the first half: browsing a trail in another country is not walking
    /// it, and the badge must not quietly become a reading for wherever the
    /// reader is sitting.
    @Test("a selected trail stays put for a hiker nowhere near it")
    func trailStaysPutForADistantHiker() {
        let focus = WeatherFocus()
        focus.focus(on: trail(at: budapest))

        // Well outside the follow radius.
        focus.hikerMoved(to: vienna)

        #expect(focus.subject?.coordinate.latitude == budapest.latitude)
    }

    /// A searched place never follows anyone. Someone reading Budapest's
    /// forecast from Vienna asked about Budapest.
    @Test("a searched place never follows the hiker")
    func placeNeverFollows() {
        let focus = WeatherFocus()
        focus.focus(on: .place(budapest, name: "Budapest"))

        focus.hikerMoved(to: vienna)

        #expect(focus.subject == .place(budapest, name: "Budapest"))
    }

    /// With nothing selected, nothing recording and nothing searched, the
    /// badge is about here — otherwise a launch that restores no selection has
    /// no subject at all and the badge would never refresh.
    @Test("with nothing else focused the hiker becomes the subject")
    func defaultsToTheHiker() {
        let focus = WeatherFocus()
        focus.defaultToHiker(at: budapest)
        #expect(focus.subject == .me(budapest))
    }

    @Test("the default never displaces something already focused")
    func defaultDoesNotDisplace() {
        let focus = WeatherFocus()
        focus.focus(on: .place(vienna, name: "Vienna"))

        focus.defaultToHiker(at: budapest)

        #expect(focus.subject == .place(vienna, name: "Vienna"))
    }

    /// The map going to a searched city moved the badge there. The map going
    /// back to where the hiker stands has to move it back, or the badge is
    /// left on a city the map is no longer showing.
    @Test("asking where they are takes the badge from a searched place")
    func askingTakesTheBadgeFromASearch() {
        let focus = WeatherFocus()
        focus.focus(on: .place(vienna, name: "Vienna"))

        focus.focusOnHiker(at: budapest)

        #expect(focus.subject == .me(budapest))
    }

    @Test("asking where they are takes the badge from a trail they are nowhere near")
    func askingTakesTheBadgeFromADistantTrail() {
        let focus = WeatherFocus()
        focus.focus(on: trail(at: vienna))

        focus.focusOnHiker(at: budapest)

        #expect(focus.subject == .me(budapest))
    }

    /// The trail a hiker is out on follows them already, and is the same
    /// weather as here. Taking the badge from it would cost its reading and
    /// its name on the sheet for nothing.
    @Test("asking where they are keeps the trail they are out on, where they stand")
    func askingKeepsTheTrailTheyAreOn() {
        let focus = WeatherFocus()
        let selected = trail(at: budapest)
        focus.focus(on: selected)

        focus.focusOnHiker(at: nearBudapest)

        #expect(focus.subject == selected.moved(to: nearBudapest))
    }

    @Test("asking where they are makes the hiker the subject when nothing else is")
    func askingFocusesAnEmptyBadge() {
        let focus = WeatherFocus()
        focus.focusOnHiker(at: budapest)
        #expect(focus.subject == .me(budapest))
    }

    @Test("asking where they are during a recording brings the hiker's position up to date")
    func askingUnderAPinStaysTheHiker() {
        let focus = WeatherFocus()
        focus.pinToHiker(at: budapest)

        focus.focusOnHiker(at: nearBudapest)

        #expect(focus.subject == .me(nearBudapest))
        #expect(focus.isPinnedToHiker)
    }

    /// The press that matters most changes nothing: the badge is about the
    /// hiker already, standing where they stood, and its reading is a few
    /// minutes old. `subjects` is silent then, so the ask has a stream of
    /// its own for the poll to wake on.
    @Test("asking where they are is heard when it changes nothing", .timeLimit(.minutes(1)))
    func anAskThatChangesNothingIsHeard() async {
        let focus = WeatherFocus()
        focus.focusOnHiker(at: budapest)
        var asks = focus.asks().makeAsyncIterator()

        focus.focusOnHiker(at: budapest)

        // Sent before this is awaited, so it is already in the stream. A
        // press that was not heard hangs here, and the time limit says so.
        let asked = await asks.next()
        #expect(asked == WeatherSubject.me(budapest).key, "an ask names the subject it was about")
        #expect(focus.subject == .me(budapest))
    }

    /// The poll hears an ask a turn after it was made, and has to be able to
    /// tell it is about the trail the hiker is out on rather than `me`.
    @Test("an ask on the trail they are out on names that trail", .timeLimit(.minutes(1)))
    func anAskNamesTheTrailItKept() async {
        let focus = WeatherFocus()
        let selected = trail(at: budapest)
        focus.focus(on: selected)
        var asks = focus.asks().makeAsyncIterator()

        focus.focusOnHiker(at: nearBudapest)

        let asked = await asks.next()
        #expect(asked == selected.key)
    }

    /// The poll loop wakes on every change to `subject`, so re-focusing what
    /// is already showing has to be silent — otherwise re-selecting the open
    /// hike, which the UI does on several paths, would wake the loop to
    /// conclude it had nothing to do.
    @Test("re-focusing the same subject changes nothing")
    func refocusingIsIdempotent() {
        let focus = WeatherFocus()
        let place = WeatherSubject.place(budapest, name: "Budapest")
        focus.focus(on: place)
        focus.focus(on: place)
        #expect(focus.subject == place)
    }

    /// `me` is one subject whose coordinate changes, not a new subject per
    /// step — which is what lets ``WeatherRequestState`` keep one freshness
    /// window for the hiker instead of one per kilometre, the way the grid it
    /// replaced did.
    @Test("the hiker keeps one identity however far they walk")
    func hikerKeepsOneIdentity() {
        #expect(WeatherSubject.me(budapest).key == WeatherSubject.me(vienna).key)
    }

    @Test("a place and a trail in the same spot are different subjects")
    func subjectsOfDifferentKindsDoNotCollide() {
        #expect(WeatherSubject.place(budapest, name: "Budapest").key != trail(at: budapest).key)
    }
}
