//
//  Binding+Presenting.swift
//  OpenHikes
//

import SwiftUI

extension Binding {
    /// This optional as the `Bool` an `alert` or `confirmationDialog` wants,
    /// cleared when the presentation is dismissed.
    ///
    /// The pairing is what makes it worth naming. Every one of these screens
    /// keeps the *reason* it is presenting — a failure, a pending deletion,
    /// an answer from the server — in an optional, and passes that same
    /// optional to `presenting:` so the buttons act on the value the
    /// presentation was built for rather than on whatever arrived since. What
    /// `isPresented:` then needs is a `Bool` view of the same storage, and
    /// what dismissal has to do is put the optional back to `nil` — because a
    /// value left behind is a presentation that will not open a second time.
    ///
    /// Written out at each call site it is six lines of binding plumbing
    /// around one word, and the word is the only part that differed.
    ///
    /// Only the `false` direction is honoured: SwiftUI drives this to `false`
    /// on dismissal and never to `true`, and there is no value to invent if it
    /// did.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { presented in
                if !presented { wrappedValue = nil }
            }
        )
    }
}
