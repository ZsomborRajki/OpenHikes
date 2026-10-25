//
//  GPXPlaceCapCutTests.swift
//  OpenHikesTests
//
//  Where ``GPXImport/placesKept(of:)`` draws the cap's line across the
//  tracks it is given, at its edges: no tracks, empty ones, exactly the cap
//  and one past it, offsets two tracks share, and fifty tracks of a full
//  list each (#1083).
//
//  The function finds the file's first place past the cap by a bounded
//  selection rather than a sort of every candidate, and the two only agree
//  if the selection keeps the same boundary. The large cases are the ones
//  that matter for that: below ten times the cap, Swift Algorithms' selection
//  falls back to a full sort, so a small fixture never runs the bounded path.
//

@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("GPX place cap cut")
struct GPXPlaceCapCutTests {
    private static let limit = GPXImport.maximumPlaces

    private static func track(at offsets: [Int]) -> GPXImport.Track {
        GPXImport.Track(
            name: nil,
            trackDescription: nil,
            author: nil,
            keywords: nil,
            startTime: nil,
            segments: [],
            places: offsets.map { (offset: $0, element: TrailPlace(latitude: 47, longitude: 12)) }
        )
    }

    /// `count` tracks of `perTrack` places each, interleaved in the file:
    /// track `t` holds offsets `t`, `t + count`, `t + 2 × count`…
    private static func interleaved(_ count: Int, perTrack: Int) -> [GPXImport.Track] {
        (0..<count).map { track in
            Self.track(at: (0..<perTrack).map { track + $0 * count })
        }
    }

    // MARK: Which tracks

    /// A track not handed in spends nothing, though its places come first in
    /// the file (#1037).
    @Test("only the tracks given spend the cap")
    func onlyTheTracksGivenSpend() {
        let first = Self.track(at: Array(0..<Self.limit))
        let second = Self.track(at: Array(Self.limit..<(Self.limit + 50)))

        #expect(GPXImport.placesKept(of: [second]) == [50])
        #expect(GPXImport.placesKept(of: [first, second]) == [Self.limit, 0])
    }

    /// The answer is in the order the tracks were given, and what is kept is
    /// decided by the file's order, whichever track was given first.
    @Test("the cut follows the file, in the order the tracks were given")
    func cutFollowsTheFileInTheGivenOrder() {
        let early = Self.track(at: Array(0..<150))
        let late = Self.track(at: Array(150..<300))

        #expect(GPXImport.placesKept(of: [late, early]) == [50, 150])
        #expect(GPXImport.placesKept(of: [early, late]) == [150, 50])
    }

    // MARK: Empty

    @Test("no tracks, or empty ones, keep nothing")
    func emptyTracksKeepNothing() {
        let empty = Self.track(at: [])

        #expect(GPXImport.placesKept(of: []).isEmpty)
        #expect(GPXImport.placesKept(of: [empty]) == [0])
        #expect(GPXImport.placesKept(of: [empty, empty]) == [0, 0])
    }

    @Test("an empty track among tracks past the cap keeps nothing and costs nothing")
    func emptyTrackAmongFullOnes() {
        let full = Self.track(at: Array(0..<(Self.limit + 10)))
        let empty = Self.track(at: [])

        #expect(GPXImport.placesKept(of: [empty, full, empty]) == [0, Self.limit, 0])
    }

    // MARK: At the cap

    @Test("exactly the cap keeps every place, on one track or across two")
    func exactlyTheCapKeepsEverything() {
        #expect(GPXImport.placesKept(of: [Self.track(at: Array(0..<Self.limit))]) == [Self.limit])

        let evens = Self.track(at: Array(stride(from: 0, to: 300, by: 2)))
        let odds = Self.track(at: Array(stride(from: 1, to: 100, by: 2)))
        #expect(GPXImport.placesKept(of: [evens, odds]) == [150, 50])
    }

    /// One past the cap cuts the file's last place, on whichever track holds
    /// it: here the first track's own last place comes last in the file.
    @Test("one past the cap cuts only the file's last place")
    func onePastTheCapCutsTheLast() {
        #expect(GPXImport.placesKept(of: [Self.track(at: Array(0...Self.limit))]) == [Self.limit])

        let first = Self.track(at: Array(0..<100) + [Self.limit])
        let second = Self.track(at: Array(100..<Self.limit))
        #expect(GPXImport.placesKept(of: [first, second]) == [100, Self.limit - 100])
    }

    // MARK: Shared offsets

    /// The parse gives each place to one track, so no two share an offset,
    /// but a caller can. A tie at the cap cannot be split by file order, so
    /// both are cut, and the import keeps one fewer than the cap.
    @Test("an offset two tracks share at the cap is cut from both")
    func tieAtTheCapIsCutFromBoth() {
        let first = Self.track(at: Array(0..<Self.limit))
        let second = Self.track(at: [Self.limit - 1])

        #expect(GPXImport.placesKept(of: [first, second]) == [Self.limit - 1, 0])
    }

    @Test("shared offsets inside the cap are all kept, and past it all cut")
    func sharedOffsetsAwayFromTheCap() {
        let first = Self.track(at: Array(0..<(Self.limit - 1)))
        let second = Self.track(at: [Self.limit - 2])
        #expect(GPXImport.placesKept(of: [first, second]) == [Self.limit - 1, 1])

        let full = Self.track(at: Array(0..<Self.limit))
        let late = Self.track(at: [Self.limit + 5, Self.limit + 5])
        #expect(GPXImport.placesKept(of: [full, late, late]) == [Self.limit, 0, 0])
    }

    // MARK: Many tracks

    /// The issue's probe: fifty tracks of one more than the cap each,
    /// interleaved in the file, which is far past the size at which the
    /// selection stops sorting everything.
    @Test("fifty interleaved tracks past the cap share it by the file's order")
    func fiftyInterleavedTracks() {
        let tracks = Self.interleaved(50, perTrack: Self.limit + 1)

        #expect(GPXImport.placesKept(of: tracks) == Array(repeating: Self.limit / 50, count: 50))
        #expect(GPXImport.placesKept(of: Array(tracks.reversed())) == Array(repeating: Self.limit / 50, count: 50))
    }

    /// Fifty full tracks one after another in the file, handed in last
    /// first: the first track in the file keeps the cap, and no other keeps
    /// anything.
    @Test("fifty tracks one after another keep the first one's places")
    func fiftyTracksInSequence() {
        let span = Self.limit + 1
        let tracks = (0..<50).map { Self.track(at: Array(($0 * span)..<(($0 + 1) * span))) }

        var expected = Array(repeating: 0, count: 50)
        expected[49] = Self.limit
        #expect(GPXImport.placesKept(of: Array(tracks.reversed())) == expected)
    }

    /// A boundary that falls part-way into one track among many: forty-nine
    /// tracks of three places, then the rest of the cap and more on the last.
    @Test("the cut can fall part-way into one track among many")
    func cutFallsInsideOneTrack() {
        let small = (0..<49).map { Self.track(at: Array(($0 * 3)..<($0 * 3 + 3))) }
        let large = Self.track(at: Array(147..<(147 + 2 * Self.limit)))

        #expect(GPXImport.placesKept(of: small + [large]) == Array(repeating: 3, count: 49) + [Self.limit - 147])
    }
}
