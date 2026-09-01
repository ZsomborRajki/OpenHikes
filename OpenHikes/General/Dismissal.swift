//
//  Dismissal.swift
//  OpenHikes
//
//  The two ways a screen closes itself, each as its own boundary: a button
//  that dismisses, and a condition that does.
//
//  Both exist for one reason. `@Environment(\.dismiss)` is a
//  `DynamicProperty`, so — like `@State`, and for the same reason — it
//  invalidates the view that *declares* it whether or not the body reads it.
//  And `DismissAction` is replaced far more often than a sheet is closed:
//  SwiftUI hands out a fresh, non-equatable one on every pass through the
//  presentation machinery, which a scene-phase transition drives several times.
//  A screen that declares it therefore re-renders in full every time the app
//  leaves or re-enters the foreground, for a value nothing on screen depends
//  on.
//
//  Measured, on the `photo-discovery` scenario: one backgrounding re-evaluated
//  `PhotoDiscoverySheet` eight times, rebuilding a twelve-cell grid, its
//  toolbar and every cell's accessibility label — and SwiftUI's own
//  `_logChanges` named `_dismiss` as the only property that had changed in
//  seven of the eight. The same shape cost `HikePhotoViewer` seven passes
//  (each re-sorting the gallery) and `SettingsView` six of a seven-section
//  `Form`.
//
//  Declaring it here instead moves the read into a leaf, which is the same
//  rule the rest of the render-isolation work follows: only a `View` type is a
//  boundary — and a `ViewModifier` is one too, since its dynamic properties
//  are its own and its `body(content:)` re-wraps a subtree the parent already
//  built.
//

import SwiftUI

/// A button that closes the presentation it is in, and the only thing that
/// reads ``EnvironmentValues/dismiss`` in doing so.
///
/// Put it straight in the toolbar — `ToolbarItem { DismissButton() }` — rather
/// than writing `Button("Done") { dismiss() }` there. A `.toolbar` closure is
/// inlined into the body that declares it, so the environment read would
/// belong to the screen and not to the button.
///
/// An accessibility identifier applied from the outside still lands on the
/// button underneath, so a caller that needs one attaches it as a modifier
/// rather than passing it in.
struct DismissButton: View {
    private let title: LocalizedStringKey

    @Environment(\.dismiss)
    private var dismiss

    init(_ title: LocalizedStringKey = "Done") {
        self.title = title
    }

    var body: some View {
        Button(title) { dismiss() }
    }
}

/// Closes the presentation the moment `condition` becomes true.
///
/// The non-button half of the same rule, for the two screens that dismiss
/// themselves rather than being dismissed: the photo viewer when its last
/// photograph is deleted, and the paywall when the purchase lands.
private struct DismissWhen: ViewModifier {
    let condition: Bool

    @Environment(\.dismiss)
    private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: condition) { _, met in
            if met { dismiss() }
        }
    }
}

extension View {
    /// Closes this presentation the first time `condition` becomes true.
    ///
    /// Only on the transition, never on the initial value — a screen that
    /// opens with the condition already met stays up, exactly as the
    /// `.onChange` this replaces behaved.
    func dismiss(when condition: Bool) -> some View {
        modifier(DismissWhen(condition: condition))
    }
}
