//
//  HikeListElevationOrderingTests.swift
//  OpenHikesTests
//
//  The Hilliest list's task, one save at a time, with the hikes list's
//  `@Query` up as the sheet always has it (#1253). A save costs a look at
//  history and the lines of the hikes it names, and no others. Whatever
//  lands late changes nothing: a look or a measurement still out when the
//  task is cancelled, as switching the list to another order cancels it,
//  and figures measured from a line that a write or a save replaced
//  meanwhile.
//
//  Both seams wrap the real work: each measurement reads and measures the
//  lines it is handed, and each look reads the store's history. The suite
//  holds them, to move something on while one is out, and counts them: the
//  hikes a measurement is handed are the routes it reads.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Library elevation, one save at a time")
struct HikeListElevationOrderingTests {
    /// Where a cancelled task was when the list moved on.
    enum Moment: String, CaseIterable, Sendable {
        case looking = "looking at history"
        case measuring = "measuring a line"
    }

    /// Who writes the lines.
    enum Writer: String, CaseIterable, Sendable {
        case elsewhere = "elsewhere"
        case here = "here"
    }

    private struct Watching {
        let stage: HikeListElevationStage
        let measurements: HeldMeasurements
        let looks: HeldLooks
        let task: Task<Void, Never>

        /// The hikes each measurement after the first pass was handed.
        var measuredSinceFirstPass: [[UUID]] { Array(measurements.calls.dropFirst()) }
    }

    /// The stage's library with the list's task running, and its first pass
    /// published and looked past: every listed hike measured once, and
    /// history read once, from when that pass began. `failing` names looks
    /// that cannot read history, counting from the first after that.
    private func watching(failing: Set<Int> = []) async throws -> Watching {
        let stage = try await HikeListElevationStage(hostingTheList: true)
        let measurements = HeldMeasurements()
        let looks = HeldLooks(failing: failing)
        let task = Task {
            await HikeListMetrics.observeElevation(
                in: stage.hikes,
                container: stage.container,
                measuring: measurements.measure,
                checking: looks.look
            ) {
                stage.didPublish()
            }
        }
        await settleDelegateHop(until: "the first pass is published, and looked past") {
            stage.publications == 1 && looks.completed == 1
        }
        #expect(measurements.calls == [stage.hikes.map(\.id)])
        return Watching(stage: stage, measurements: measurements, looks: looks, task: task)
    }

    private func write(
        _ line: [RouteCoordinate],
        on hike: Hike,
        _ writer: Writer,
        in stage: HikeListElevationStage
    ) async throws {
        switch writer {
        case .elsewhere:
            try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: stage.container) { stored in
                stored.replaceRoute(with: line)
            }
        case .here:
            hike.replaceRoute(with: line)
            try stage.container.mainContext.save()
        }
    }

    /// Until an import gives the list its first token, a look reads only
    /// imports, so a tint saved here first costs the look and no line. The
    /// rename received then gives it one, and the next tint here is read.
    @Test("a save of one listed hike reads that hike's line alone, and a save of the other store reads none")
    func eachSaveReadsOnlyTheLinesItNames() async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }

        stage.hikes[1].tintHex = "#FF00FF"
        try stage.container.mainContext.save()
        await settleDelegateHop(until: "the tint is looked at, with no token yet") {
            watching.looks.completed == 2
        }
        await settleDelegateHop()
        #expect(watching.measurements.calls.count == 1, "a look with no token reads only imports")
        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hikes[2].id, in: stage.container) { hike in
            hike.title = "Renamed elsewhere"
        }
        await settleDelegateHop(until: "the rename is looked at, measured and looked past") {
            watching.measurements.calls.count == 2 && watching.looks.completed == 4
        }
        stage.hikes[3].tintHex = "#00FFFF"
        try stage.container.mainContext.save()
        await settleDelegateHop(until: "the tint is looked at by token, measured and looked past") {
            watching.measurements.calls.count == 3 && watching.looks.completed == 6
        }
        // A device-local field: its row lives in the other store.
        let changes = RemoteChangeLog()
        changes.start()
        defer { changes.stop() }
        stage.hikes[4].autoSaveTilesEnabled = false
        try stage.container.mainContext.save()
        let localStore = try #require(stage.hikes[4].localState?.persistentModelID.storeIdentifier)
        await settleDelegateHop(until: "the device-local save's change is delivered") { changes.posted(localStore) }
        await settleDelegateHop()

        #expect(watching.measuredSinceFirstPass == [[stage.hikes[2].id], [stage.hikes[3].id]])
        #expect(watching.looks.arrived == 6, "a save of the other store is dropped where it is posted")
        #expect(stage.publications == 1, "no figure changed")
    }

    @Test("a task cancelled while it is out changes nothing, and hears nothing after", arguments: Moment.allCases)
    func aCancelledTaskChangesNothing(moment: Moment) async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        let edited = stage.hikes[1]
        switch moment {
        case .looking: watching.looks.holdNext()
        case .measuring: watching.measurements.holdNext()
        }

        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, .elsewhere, in: stage)
        await settleDelegateHop(until: "the task is held \(moment.rawValue)") {
            watching.looks.held + watching.measurements.held == 1
        }
        let measured = watching.measurements.calls.count
        let looked = watching.looks.arrived
        watching.task.cancel()
        watching.looks.open()
        watching.measurements.open()
        await watching.task.value

        #expect(stage.publications == 1)
        #expect(stage.has(edited, climbing: HikeListElevationStage.climb(1)), "left for the next task to measure")
        #expect(watching.measurements.calls.count == measured, "nothing measured after the cancel")
        #expect(watching.looks.arrived == looked, "nor looked at")
        let changes = RemoteChangeLog()
        changes.start()
        defer { changes.stop() }
        try await write(HikeListElevationStage.line(2, climb: 400), on: stage.hikes[2], .elsewhere, in: stage)
        let hikesStore = try #require(edited.persistentModelID.storeIdentifier)
        await settleDelegateHop(until: "the next save's change is delivered") { changes.posted(hikesStore) }
        await settleDelegateHop()

        #expect(watching.measurements.calls.count == measured)
        #expect(watching.looks.arrived == looked, "the task ended with the list's")
    }

    /// The first new line is measured, and that measurement is held once it
    /// has read the line; the second is written, and the first let land.
    @Test(
        "a line replaced while it is measured is measured again, and figures from the line before never land",
        arguments: Writer.allCases
    )
    func aLineReplacedWhileMeasuredIsNotPublished(writer: Writer) async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]
        watching.measurements.holdNext()

        try await write(HikeListElevationStage.line(1, climb: 300), on: edited, writer, in: stage)
        await settleDelegateHop(until: "the first new line is measured") { watching.measurements.held == 1 }
        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, writer, in: stage)
        watching.measurements.open()
        await settleDelegateHop(until: "the second new line is published") { stage.has(edited, climbing: 500) }

        #expect(stage.publications == 2)
        #expect(!stage.published(climbing: 300), "the first new line's figures were dropped")
        #expect(watching.measuredSinceFirstPass == [[edited.id], [edited.id]])
    }

    @Test("two lines saved close together end on the second, and read no other hike's line")
    func twoSavesEndOnTheSecond() async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]

        try await write(HikeListElevationStage.line(1, climb: 300), on: edited, .elsewhere, in: stage)
        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, .elsewhere, in: stage)
        await settleDelegateHop(until: "the second line is published") { stage.has(edited, climbing: 500) }

        #expect(stage.lastPublished(climbing: 500), "and nothing after it")
        #expect(watching.measuredSinceFirstPass.allSatisfy { $0 == [edited.id] })
    }

    /// The first pass is held once it has read every line, a new line is
    /// saved for one of them, and the pass let land.
    @Test("a line saved while the first pass is out is measured again, and its line before never lands")
    func aLineSavedDuringTheFirstPass() async throws {
        let stage = try await HikeListElevationStage(hostingTheList: true)
        defer { stage.close() }
        let edited = stage.hikes[1]
        let measurements = HeldMeasurements()
        measurements.holdNext()
        let task = Task {
            await HikeListMetrics.observeElevation(
                in: stage.hikes,
                container: stage.container,
                measuring: measurements.measure,
                checking: StoreHistoryCheck.answer
            ) {
                stage.didPublish()
            }
        }
        defer { task.cancel() }
        await settleDelegateHop(until: "the first pass has read every line") { measurements.held == 1 }

        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, .elsewhere, in: stage)
        measurements.open()
        await settleDelegateHop(until: "the new line is published") { stage.has(edited, climbing: 500) }

        #expect(!stage.published(climbing: HikeListElevationStage.climb(1)), "measured from the line before")
        #expect(stage.has(stage.hikes[2], climbing: HikeListElevationStage.climb(2)), "the rest of the pass landed")
        #expect(Array(measurements.calls.dropFirst()) == [[edited.id]])
    }

    /// A line written here moves its hike's revision, which needs no history.
    @Test("a line written here is measured even while history cannot be read")
    func aLineWrittenHereNeedsNoHistory() async throws {
        let watching = try await watching(failing: Set(1...10))
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]

        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, .here, in: stage)
        await settleDelegateHop(until: "the new line is published") { stage.has(edited, climbing: 500) }

        #expect(watching.measuredSinceFirstPass == [[edited.id]])
    }

    /// The task cannot measure every listed line for a look that failed:
    /// that is the pass a save used to cost, and a failure that held would
    /// ask for it again after every look. Nor can it wait for another save,
    /// which may never come: the failed look took the only wake this one had.
    @Test("a look that cannot read history reads no line, and the look it asks for at once finds what it missed")
    func aFailedLookReadsNoLine() async throws {
        let watching = try await watching(failing: [1])
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]

        try await write(HikeListElevationStage.line(1, climb: 500), on: edited, .elsewhere, in: stage)
        await settleDelegateHop(until: "the line saved as the look failed is published, with no other save") {
            stage.has(edited, climbing: 500)
        }

        #expect(watching.measuredSinceFirstPass == [[edited.id]], "no other line read for the failure")
        #expect(watching.looks.arrived == 4, "the failed look, the one it asked for, and the one after measuring")
    }

    /// The look a failure asks for is the only one it asks for: a failure
    /// that held would otherwise look again, and fail, as fast as it could.
    @Test("a failure that holds asks for one more look, and none after it")
    func aFailureThatHoldsAsksForOneMore() async throws {
        let watching = try await watching(failing: Set(1...10))
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }

        try await write(HikeListElevationStage.line(1, climb: 500), on: stage.hikes[1], .elsewhere, in: stage)
        await settleDelegateHop(until: "the failed look and the one it asked for have landed") {
            watching.looks.completed == 3
        }
        // The next save's look is the effect that must follow: a third look
        // asked for by the second failure would land before it.
        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hikes[2].id, in: stage.container) { hike in
            hike.title = "Renamed elsewhere"
        }
        await settleDelegateHop(until: "the next save's look has landed") { watching.looks.completed == 4 }
        await settleDelegateHop()

        #expect(watching.looks.arrived == 4, "a look for each save, and one more for the first failure")
        #expect(watching.measurements.calls.count == 1, "no line read while history cannot be read")
        #expect(stage.publications == 1)
    }
}

/// Holds the next call of a seam, once armed, until the test opens it.
nonisolated private final class Gate: Sendable {
    private let armed = Mutex(false)
    private let state = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func arm() { armed.withLock { $0 = true } }

    /// Whether this call is the one to hold, disarming the gate if it is.
    func takes() -> Bool {
        armed.withLock { isArmed in
            defer { isArmed = false }
            return isArmed
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// The list's measurements, and the hikes each was handed. The one held is
/// held once it has read and measured its lines, so it lands with figures
/// from the lines as they were when it read them.
nonisolated private final class HeldMeasurements: Sendable {
    private let log = Mutex<[[UUID]]>([])
    private let holds = Mutex(0)
    private let gate = Gate()

    var calls: [[UUID]] { log.withLock { $0 } }
    var held: Int { holds.withLock { $0 } }

    func holdNext() { gate.arm() }

    func open() { gate.open() }

    @concurrent
    func measure(_ hikeIDs: [UUID], in container: ModelContainer) async -> [HikeListMetrics.ElevationMeasurement] {
        log.withLock { $0.append(hikeIDs) }
        let measured = await HikeListMetrics.measureElevation(for: hikeIDs, in: container)
        if gate.takes() {
            holds.withLock { $0 += 1 }
            await gate.wait()
        }
        return measured
    }
}

/// The list's looks at history: how many arrived, and how many landed. The
/// one held is held before it reads. The ones named failing, counting from
/// the first after the first pass, answer as history that cannot be read.
nonisolated private final class HeldLooks: Sendable {
    private let counts = Mutex<(arrived: Int, completed: Int)>((0, 0))
    private let holds = Mutex(0)
    private let gate = Gate()
    private let failing: Set<Int>

    init(failing: Set<Int>) {
        self.failing = failing
    }

    var arrived: Int { counts.withLock { $0.arrived } }
    var completed: Int { counts.withLock { $0.completed } }
    var held: Int { holds.withLock { $0 } }

    func holdNext() { gate.arm() }

    func open() { gate.open() }

    @concurrent
    func look(_ request: StoreHistoryCheck.Request) async -> StoreHistoryCheck.Answer {
        let sinceFirstPass = counts.withLock { tally in
            tally.arrived += 1
            return tally.arrived - 1
        }
        if gate.takes() {
            holds.withLock { $0 += 1 }
            await gate.wait()
        }
        let answer = failing.contains(sinceFirstPass)
            ? StoreHistoryCheck.Answer(token: nil, savedRows: request.rows, wasRead: false)
            : await StoreHistoryCheck.answer(request)
        counts.withLock { $0.completed += 1 }
        return answer
    }
}
