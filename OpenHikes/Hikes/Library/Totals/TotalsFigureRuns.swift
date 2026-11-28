//
//  TotalsFigureRuns.swift
//  OpenHikes
//
//  A formatted figure cut into its numbers and its units, so *Totals* can
//  draw "614 km" the way Health and Fitness draw a figure: the number large,
//  the unit small beside it.
//
//  Cut from the text the formatter wrote, and not formatted a second time
//  with attributes: the figure drawn is then the very string the rest of the
//  app writes for it, whichever formatter that was (a distance, a height
//  through `HikeFormat`, a duration), and no second spelling can drift from
//  the first.
//
//  The rule is the one a reader applies. A digit is the number. So is the
//  one character between two digits that is not a letter, which is how
//  every locale groups thousands and marks a decimal: "27 224", "9,3",
//  "1.058". Everything else is the unit, the space ahead of it included:
//  " km", "h ", "時間". A figure with no digit in it, the dash a formatter
//  writes for a figure that is not a number, is all number.
//

import Foundation

nonisolated enum TotalsFigureRuns {
    struct Run: Equatable, Sendable {
        let text: String
        let isUnit: Bool
    }

    static func runs(of figure: String) -> [Run] {
        let characters = Array(figure)
        guard characters.contains(where: \.isNumber) else {
            return figure.isEmpty ? [] : [Run(text: figure, isUnit: false)]
        }
        var runs: [Run] = []
        for index in characters.indices {
            let isUnit = !isNumber(at: index, in: characters)
            let character = String(characters[index])
            if let last = runs.last, last.isUnit == isUnit {
                runs[runs.count - 1] = Run(text: last.text + character, isUnit: isUnit)
            } else {
                runs.append(Run(text: character, isUnit: isUnit))
            }
        }
        return runs
    }

    private static func isNumber(at index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        if character.isNumber { return true }
        guard !character.isLetter else { return false }
        let followsDigit = index > 0 && characters[index - 1].isNumber
        let precedesDigit = index + 1 < characters.count && characters[index + 1].isNumber
        return followsDigit && precedesDigit
    }
}
