//
//  SerialAsyncQueueTests.swift
//  OpenTrailsTests
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("Serial async queue")
struct SerialAsyncQueueTests {
    private actor Recorder {
        private(set) var values: [Int] = []
        private(set) var concurrentPeak = 0
        private var running = 0

        func begin() {
            running += 1
            concurrentPeak = max(concurrentPeak, running)
        }

        func end(_ value: Int) {
            running -= 1
            values.append(value)
        }
    }

    @Test("operations run in submission order")
    func runsInSubmissionOrder() async {
        let queue = SerialAsyncQueue()
        let recorder = Recorder()

        for value in 0..<50 {
            queue.enqueue {
                await recorder.begin()
                // Yield so a queue that only *starts* operations in order
                // still has the chance to finish them out of order.
                await Task.yield()
                await recorder.end(value)
            }
        }
        await queue.drain()

        #expect(await recorder.values == Array(0..<50))
    }

    @Test("only one operation runs at a time")
    func runsOneAtATime() async {
        let queue = SerialAsyncQueue()
        let recorder = Recorder()

        for value in 0..<20 {
            queue.enqueue {
                await recorder.begin()
                try? await Task.sleep(for: .milliseconds(1))
                await recorder.end(value)
            }
        }
        await queue.drain()

        #expect(await recorder.concurrentPeak == 1)
    }

    @Test("draining waits for everything submitted before it")
    func drainIsABarrier() async {
        let queue = SerialAsyncQueue()
        let recorder = Recorder()

        queue.enqueue {
            await recorder.begin()
            try? await Task.sleep(for: .milliseconds(50))
            await recorder.end(1)
        }
        queue.enqueue {
            await recorder.begin()
            await recorder.end(2)
        }
        await queue.drain()

        // The barrier is the point of the type: the old task-chaining could
        // order operations but never answer "is the queue empty yet?".
        #expect(await recorder.values == [1, 2])
    }

    @Test("submitting from concurrent tasks keeps every operation")
    func concurrentSubmissionKeepsEveryOperation() async {
        let queue = SerialAsyncQueue()
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for value in 0..<100 {
                group.addTask {
                    queue.enqueue {
                        await recorder.begin()
                        await recorder.end(value)
                    }
                }
            }
        }
        await queue.drain()

        #expect(await recorder.values.count == 100)
        #expect(await Set(recorder.values) == Set(0..<100))
    }
}
