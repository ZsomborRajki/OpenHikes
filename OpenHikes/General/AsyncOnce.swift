//
//  AsyncOnce.swift
//  OpenHikes
//
//  One value, built once, however many callers ask for it at the same time.
//

/// A value produced by an `async` call the first time it is asked for, and
/// handed to every caller after that — including the ones that ask while the
/// first call is still running.
///
/// This is a type rather than three lines at each call site because those
/// three lines are wrong in a way that compiles, reads correctly and usually
/// works:
///
/// ```swift
/// if let cached { return cached }
/// let made = await build()   // ← the actor is not held here
/// cached = made
/// return made
/// ```
///
/// An actor's mutual exclusion ends at every `await`. A second caller
/// arriving while the first is suspended inside `build()` finds `cached`
/// still `nil`, passes the same guard, and builds a second one. For a cache
/// that is a wasted call nobody notices. For something the system allows only
/// one of — a `CLMonitor` under a given name, which is what wrote this file —
/// it is an uncatchable Objective-C exception and a terminated process, on a
/// window two callers have to arrive inside to hit at all.
///
/// Storing the *task* rather than the value closes the window: making it and
/// storing it are both synchronous, so nothing can run in between, and
/// awaiting a task that has already finished simply returns its value again.
/// The task is the cache.
actor AsyncOnce<Value: Sendable> {
    private let build: @Sendable () async -> Value
    private var task: Task<Value, Never>?

    init(_ build: @escaping @Sendable () async -> Value) {
        self.build = build
    }

    /// The value: awaited on the first call, returned by every one after it.
    var value: Value {
        get async {
            if let task { return await task.value }
            // Unstructured, so that a caller cancelled while it waits does not
            // cancel the build out from under the callers still waiting on it.
            let started = Task { await build() }
            task = started
            return await started.value
        }
    }
}
