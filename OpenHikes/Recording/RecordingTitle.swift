//
//  RecordingTitle.swift
//  OpenHikes
//
//  The name a recording is offered, put together from what the walk knows of
//  itself: the town it started in, the trail it mostly followed, a word for a
//  loop, and the day. "Schönau am Königssee – Malerwinkel Loop – 20 Nov 2026".
//
//  The parts are ``HikeRecorder``'s to find — see `HikeRecorder+PlaceName.swift`
//  — and this is only their order and their words. A part the walk does not
//  have is left out, down to the town and the day, which is the name a walk
//  no trail named has always had. With neither a town nor a trail there is
//  nothing to say that the time of day does not, and the answer is `nil`.
//
//  ## The word for a loop
//
//  Said only of a walk that came back by other ground than it went out on —
//  see ``RouteShape`` — and never twice: a trail called "Malerwinkel-Rundweg"
//  has said it already, in the language of the country it is in, which is
//  rarely the app's. ``saysLoop(_:)`` reads a name for the word in the
//  languages a trail is likely to be named in. A name it misses gets the word
//  a second time, in a field the hiker is shown selected; one it wrongly
//  hears the word in only goes without. So it listens widely.
//
//  Each language sets the word beside the trail's name in a way that leaves
//  the name as it is, for the reason every catalogued sentence that names
//  something does: a trail's name is somebody else's text, and nothing here
//  knows its gender or its case.
//
//  ## A name too long for a title
//
//  A title is bounded, and the cut is made from the end (``HikeTitle``). A
//  route relation's name can be a paragraph, and cut whole, it took the
//  loop's word and the day with it, so two walks of the same trail on two
//  days were offered one name. So the day, the loop's word and the
//  separators take their room first, and the town and the trail share what
//  is left: the town as much as it needs up to half of it, and the trail the
//  rest, since the trail's name is the one that runs long.
//

import Foundation
import OpenHikesData

nonisolated enum RecordingTitle {
    /// What stands between two parts of a name, as it always has between the
    /// time of day and the date.
    static let separator = " – "

    /// The name of a walk with these parts, or `nil` when it has neither a
    /// town nor a trail to be named for.
    ///
    /// Bounded through ``HikeTitle``, like every name this app did not get
    /// from a keyboard: the town is MapKit's text and the trail's name is
    /// OpenStreetMap's, both arriving over the network, and a route
    /// relation's name is occasionally a paragraph. What a long name gives
    /// up is its own end, never the loop's word or the day — see *A name too
    /// long for a title* above.
    ///
    /// - Parameters:
    ///   - city: The town the walk started in.
    ///   - trail: The trail it mostly followed.
    ///   - shape: The line it drew. Only a loop is said, and only beside a
    ///     trail's name.
    ///   - date: When it started.
    static func title(
        city: String?,
        trail: String?,
        shape: RouteShape?,
        date: Date,
        calendar: Calendar = .current
    ) -> String? {
        let trailName = named(trail)
        // A trail named for its town says the town once.
        let town = named(city).flatMap { town in
            trailName?.caseInsensitiveCompare(town) == .orderedSame ? nil : town
        }
        guard town != nil || trailName != nil else { return nil }
        let isLoop = shape == .loop && trailName.map { !saysLoop($0) } ?? false
        let dayPart = day(date, calendar: calendar)

        var room = Room()
        room.take(dayPart)
        room.take(separator)
        if town != nil, trailName != nil { room.take(separator) }
        if isLoop { room.take(loop("")) }
        let fittedTown = town.flatMap { room.fit($0, sharing: trailName == nil ? 1 : 2) }
        let fittedTrail = trailName.flatMap { room.fit($0) }
        guard fittedTown != nil || fittedTrail != nil else { return nil }
        let trailPart = fittedTrail.map { isLoop ? loop($0) : $0 }
        return HikeTitle.bounded(
            [fittedTown, trailPart, dayPart]
                .compactMap(\.self)
                .joined(separator: separator)
        )
    }

    /// A trail's name with the word for a loop beside it.
    private static func loop(_ name: String) -> String {
        String(localized: "\(name) Loop")
    }

    /// What is left of a title's bound, in both its units, as the parts are
    /// given their room.
    private struct Room {
        /// The bytes a bound allows each of its characters.
        private static let bytesPerCharacter = HikeTitle.maximumUTF8Bytes / HikeTitle.maximumCharacters

        private var characters = HikeTitle.maximumCharacters
        private var utf8Bytes = HikeTitle.maximumUTF8Bytes

        /// Gives `text` its room whole.
        ///
        /// A sum of the parts' counts, which the joined text can only come in
        /// under: a part that opens with a combining mark joins the character
        /// before it rather than adding one.
        mutating func take(_ text: String) {
            characters -= text.count
            utf8Bytes -= text.utf8.count
        }

        /// As much of `name` as fits in one `share`-th of the room left,
        /// trimmed, and `nil` when none of it does. Whatever it takes is taken.
        ///
        /// Cut by ``BoundedText``, as every title is, to a bound whose bytes
        /// fit too: a bound allows each character
        /// ``bytesPerCharacter``, so it is held to the bytes left as well.
        mutating func fit(_ name: String, sharing share: Int = 1) -> String? {
            let allowed = min(characters, utf8Bytes / Self.bytesPerCharacter) / share
            let fitted = BoundedText.bounded(name, to: TextBound(characters: max(0, allowed)))
            if let fitted { take(fitted) }
            return fitted
        }
    }

    /// The day every default name ends with.
    ///
    /// `Date.FormatStyle` rather than `DateFormatter`: the old formatter is an
    /// `NSObject` that had to be built and configured on every call, and this
    /// runs once per saved recording. A format style is a `Sendable` value,
    /// which is also what lets this stay `nonisolated` without parking a
    /// shared mutable formatter somewhere.
    ///
    /// `.abbreviated` is `DateFormatter`'s `.medium`. Locale and time zone stay
    /// at the system's, as they were.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar))
    }

    /// Whether a trail's own name already says it is a loop.
    static func saysLoop(_ name: String) -> Bool {
        folded(name)
            .split { !$0.isLetter }
            .contains { word in
                loopWords.contains(String(word)) || loopStems.contains { word.contains($0) }
            }
    }

    /// A part with something in it, trimmed.
    private static func named(_ part: String?) -> String? {
        guard let name = part?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// A name as the lists below are compared with it: without case or
    /// accents, so "Pętla", "PĘTLA" and "petla" are one word.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Words that mean a loop when they stand alone in a name.
    private static let loopWords = Set(
        [
            "loop", "circuit", "circular", "round",
            "runde",
            "boucle", "tour",
            "circuito", "vuelta", "anillo",
            "anello", "giro",
            "коло", "навколо",
            "dookoła", "wokół",
            "rondje", "ommetje",
            "slinga", "rundan",
        ].map(folded)
    )

    /// Pieces of a word that mean a loop wherever they stand in it, for the
    /// languages that build the word into a longer one ("Seerundweg") or
    /// decline it ("кольцевой", "pętli").
    private static let loopStems = [
        "rundweg", "rundwander", "rundtour", "rundgang", "rundkurs", "rundstrecke", "rundtur",
        "кольц", "круг",
        "кільц",
        "pętl", "okrężn",
        "körtúra", "körút", "körséta",
        "rondwandel",
        "okruh",
    ].map(folded)
}
