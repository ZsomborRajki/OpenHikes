//
//  TrailPlaceFoundIndex.swift
//  OpenHikes
//
//  Which rows *Places Around Trail* has already found, by row and by
//  OpenStreetMap element, so that a new answer is merged in one pass over it.
//
//  ## Why an index beside the list
//
//  The corridor asks up to a dozen requests, each of which may answer with a
//  couple of hundred places, and every *Search This Area* adds to the same
//  list, which an answer may repeat in full. Looking each
//  incoming row up in the list itself made a merge quadratic, on the main
//  actor. This keeps, for every row found, where it sits in the list under its
//  id and under its element, so each incoming row costs two dictionary
//  lookups.
//
//  The list itself stays an observed array on ``HikePlacesAroundSearch``,
//  written only when something is added, so a repeated answer redraws
//  nothing. The index records each row it hands back to be appended, in that
//  order, so it stays in step with a list that nothing else writes.
//
//  ## The same rule as before
//
//  An incoming row stands for the first row already found that has its id or
//  is its element, and keeps that row's id. A row that is neither is added,
//  unless an earlier row of the same answer is its element. Where a row
//  matches one found row by id and another by element, the earlier of the two
//  wins, as a scan from the front would have found it.
//

import Foundation
import OpenHikesData

struct TrailPlaceFoundIndex {
    /// An OpenStreetMap element, without the facts it carries.
    nonisolated struct Element: Hashable, Sendable {
        let type: String
        let id: Int64
    }

    /// What one answer brings: the rows to append, in the order given, and
    /// the ids that now stand for every row given.
    struct Merge {
        var added: [TrailPlaceRow] = []
        var ids: Set<UUID> = []
    }

    /// Reads a place's element. Injected so that a suite can count how often
    /// a merge has to read one.
    typealias ElementOf = (TrailPlace) -> Element?

    private let element: ElementOf
    /// Where each id first appears in the list.
    private var positions: [UUID: Int] = [:]
    /// Where each element appears in the list, and the id of the row there.
    private var elements: [Element: (position: Int, id: UUID)] = [:]
    /// How many rows the list holds.
    private var count = 0

    init(element: @escaping ElementOf = Self.element) {
        self.element = element
    }

    nonisolated static func element(_ place: TrailPlace) -> Element? {
        place.osm.map { Element(type: $0.elementType, id: $0.elementID) }
    }

    /// Where the first row with `id` sits in the list.
    func position(of id: UUID) -> Int? {
        positions[id]
    }

    /// Merges `rows` into what was found, and records what it adds: the
    /// caller appends ``Merge/added`` to its list.
    mutating func merge(_ rows: [TrailPlaceRow]) -> Merge {
        var merge = Merge()
        var addedElements: [Element?] = []
        var seen: Set<Element> = []
        for row in rows {
            let key = element(row.place)
            if let existing = existing(row.id, key) {
                merge.ids.insert(existing)
            } else if key.map({ seen.insert($0).inserted }) ?? true {
                merge.added.append(row)
                addedElements.append(key)
                merge.ids.insert(row.id)
            }
        }
        for (row, key) in zip(merge.added, addedElements) {
            if positions[row.id] == nil { positions[row.id] = count }
            if let key, elements[key] == nil { elements[key] = (count, row.id) }
            count += 1
        }
        return merge
    }

    /// The id of the first found row with `id` or of `key`, if there is one.
    private func existing(_ id: UUID, _ key: Element?) -> UUID? {
        let byID = positions[id]
        guard let key, let byElement = elements[key] else { return byID.map { _ in id } }
        guard let byID, byID < byElement.position else { return byElement.id }
        return id
    }
}
