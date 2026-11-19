//
//  SortMenuEqualityTests.swift
//  OpenHikesTests
//
//  The hikes list and *Offline Maps* build their order capsule again on every
//  pass, each time with a new binding. They apply `.equatable()`, so that a
//  copy differing only in that binding is the same capsule and its body does
//  not run again — see `SortMenu+Equatable.swift`. What is pinned here is the
//  comparison: the binding is left out of it, the order it reads is not, and
//  neither is anything the capsule draws or says.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Sort menu equality")
struct SortMenuEqualityTests {
    private enum Order: Hashable {
        case newest, longest
    }

    private static let options = [
        SortMenuOption(value: Order.newest, title: "Newest First", symbol: "calendar"),
        SortMenuOption(value: Order.longest, title: "Longest", symbol: "ruler"),
    ]

    /// A capsule over `selection`, through a binding of its own, as each pass
    /// of a list makes one.
    private func menu(
        selection: Order? = .newest,
        options: [SortMenuOption<Order>] = options,
        title: String = "Newest First",
        label: LocalizedStringResource = "Sort hikes",
        value: String? = nil,
        identifier: String = "hike-order-button",
        onSet: @escaping (Order?) -> Void = { _ in /* No list to reorder. */ }
    ) -> SortMenu<Order> {
        SortMenu(
            options: options,
            selection: Binding(get: { selection }, set: onSet),
            title: title,
            label: label,
            value: value,
            identifier: identifier
        )
    }

    @Test("a capsule built again over the same order, with a new binding, is the same capsule")
    func newBindingSameOrder() {
        let other = menu(onSet: { _ in Issue.record("comparing reads the order and writes nothing") })
        #expect(menu() == other)
    }

    @Test("another order in force is another capsule")
    func anotherOrder() {
        #expect(menu() != menu(selection: .longest))
        #expect(menu() != menu(selection: nil))
    }

    @Test("what the capsule says is part of it")
    func whatItSays() {
        #expect(menu() != menu(title: "Your Order"))
        #expect(menu() != menu(value: "Your order"))
        #expect(menu() != menu(label: "Sort offline maps"))
        #expect(menu() != menu(identifier: "offline-maps-order-button"))
    }

    @Test("what the capsule offers is part of it")
    func whatItOffers() {
        #expect(menu() != menu(options: Array(Self.options.prefix(1))))
        let renamed = [SortMenuOption(value: Order.newest, title: "Neueste zuerst", symbol: "calendar")]
            + Self.options.dropFirst()
        #expect(menu() != menu(options: renamed))
    }
}
