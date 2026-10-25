//
//  EarlierObservationsTests.swift
//  OpenHikesTests
//
//  The contract `observedValues(_:)` keeps below iOS 26, held on a release
//  that would otherwise never run it: the current value when iteration
//  starts, then each change once it has landed, with a burst arriving as its
//  newest value. See `ObservedValues.swift`.
//

import Observation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Observations below iOS 26")
struct EarlierObservationsTests {
    @Observable
    final class Model {
        var value = 0
    }

    @Test("iteration starts from the value already current")
    func startsFromTheCurrentValue() async {
        let model = Model()
        model.value = 7
        var values = EarlierObservations { model.value }.makeAsyncIterator()

        #expect(await values.next() == 7)
    }

    @Test("each change arrives once it has landed")
    func changesArrive() async {
        let model = Model()
        var values = EarlierObservations { model.value }.makeAsyncIterator()
        #expect(await values.next() == 0)

        model.value = 1
        #expect(await values.next() == 1, "the new value, not the one the change interrupted")
        model.value = 2
        #expect(await values.next() == 2, "the registration renewed itself after the first change")
    }

    @Test("a burst before the consumer runs arrives as its newest value")
    func aBurstArrivesAsItsNewestValue() async {
        let model = Model()
        var values = EarlierObservations { model.value }.makeAsyncIterator()
        #expect(await values.next() == 0)

        model.value = 1
        model.value = 2
        model.value = 3
        #expect(await values.next() == 3)
    }
}
