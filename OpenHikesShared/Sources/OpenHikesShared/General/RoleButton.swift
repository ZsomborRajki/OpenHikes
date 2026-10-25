//
//  RoleButton.swift
//  OpenHikesShared
//
//  A close, cancel or confirm button that the system draws where it can, and
//  that says what it does where it cannot.
//
//  iOS 26 and watchOS 26 gave `Button` a role-only form — `.close`, `.confirm`
//  and `.cancel` with no label at all — whose glyph, styling and spoken word
//  are Apple's own, and every one of this app's toolbars and dismissible
//  notices uses it. Below 26 there is no such button and no `.close` or
//  `.confirm` role to ask for, so this draws what the earlier releases
//  themselves draw there: the word, in a toolbar — Cancel, Done, Save — and
//  the role's glyph, labelled with the same word, in a pill or a notice too
//  small for one, which is what the role-only button shows there anyway.
//
//  Here rather than in the app because the watch has the same buttons, and
//  a role read one way on the wrist and another on the phone would be two
//  answers to one question.
//

import SwiftUI

/// The system's close, cancel or confirm button on iOS 26 and watchOS 26 and
/// later, and the same role in words or a glyph below them.
///
/// Modifiers applied from the outside — an accessibility identifier,
/// `disabled(_:)`, a font — land on the button underneath, as they would on
/// the `Button` this stands in for.
public struct RoleButton: View {
    /// What the button does, which is all the system needs to draw one.
    public enum Role: Sendable {
        /// Abandons what the screen holds — a typed name, a choice of tracks.
        case cancel
        /// Leaves a screen that has nothing to lose.
        case close
        /// Does what the screen is for: saves, adds, sends.
        case confirm
    }

    private let role: Role
    private let title: LocalizedStringResource
    private let isIconOnly: Bool
    private let action: () -> Void

    /// - Parameters:
    ///   - title: The word below 26, and what VoiceOver says for the glyph
    ///     there. Defaults to the word those releases use for the role:
    ///     *Cancel*, *Done* and *Done*. Pass the screen's own verb for a
    ///     confirmation — *Save*, *Add*, *Send* — because a toolbar that says
    ///     *Done* over an unsaved form is promising the wrong thing.
    ///   - isIconOnly: Draws the glyph alone on every release, for a pill or a
    ///     notice. The role-only button is a glyph there too, so this is the
    ///     one place both sides of 26 look alike.
    public init(
        _ role: Role,
        title: LocalizedStringResource? = nil,
        isIconOnly: Bool = false,
        action: @escaping () -> Void
    ) {
        self.role = role
        self.title = title ?? role.defaultTitle
        self.isIconOnly = isIconOnly
        self.action = action
    }

    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            if isIconOnly {
                Button(role: role.systemRole, action: action)
                    .labelStyle(.iconOnly)
            } else {
                Button(role: role.systemRole, action: action)
            }
        } else if isIconOnly {
            Button(role: role.earlierRole, action: action) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: role.glyph)
                }
            }
            .labelStyle(.iconOnly)
        } else {
            Button(role: role.earlierRole, action: action) {
                Text(title)
            }
        }
    }
}

extension RoleButton.Role {
    @available(iOS 26.0, macOS 26.0, watchOS 26.0, visionOS 26.0, *) var systemRole: ButtonRole {
        switch self {
        case .cancel: .cancel
        case .close: .close
        case .confirm: .confirm
        }
    }

    /// The nearest role that existed before 26: only cancelling had one.
    var earlierRole: ButtonRole? {
        switch self {
        case .cancel: .cancel
        case .close, .confirm: nil
        }
    }

    /// The glyph iOS 26 draws for the role.
    var glyph: String {
        switch self {
        case .cancel, .close: "xmark"
        case .confirm: "checkmark"
        }
    }

    var defaultTitle: LocalizedStringResource {
        switch self {
        case .cancel: "Cancel"
        case .close, .confirm: "Done"
        }
    }
}
