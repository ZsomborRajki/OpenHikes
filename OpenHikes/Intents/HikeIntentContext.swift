//
//  HikeIntentContext.swift
//  OpenHikes
//
//  How an intent finds the running app, and how a test hands it a different
//  one.
//
//  In the app the answer is `AppDependencyManager`: the system may launch this
//  process *to run an intent*, so there is no view hierarchy to reach through
//  and the launch has to have registered the coordinator itself — see
//  `OpenHikesApp.init()`.
//
//  A suite has no registered dependency at all, and asking for one that was
//  never registered traps rather than returning nil. So the override below is
//  read first and the `@Dependency` is only touched when it is absent. It is a
//  `@TaskLocal` rather than a plain `static var` deliberately: Swift Testing
//  runs suites in parallel, and a stored global would let one test's recorder
//  answer another test's intent. A task-local is scoped to the `withValue`
//  body and to whatever that body awaits, which is exactly one test.
//

import AppIntents

nonisolated enum HikeIntentContext {
    /// The coordinator an intent performed inside ``$override`` sees. `nil`
    /// everywhere else, which is every real launch.
    @TaskLocal static var override: HikeIntentCoordinator?
}

/// An intent that acts on the app rather than on its own parameters.
///
/// The `@Dependency` has to be declared on each conforming intent — a property
/// wrapper cannot be inherited from a protocol — so what this carries is only
/// the resolution order, in one place rather than six.
nonisolated protocol HikeCoordinatingIntent: AppIntent {
    var appCoordinator: HikeIntentCoordinator { get }
}

nonisolated extension HikeCoordinatingIntent {
    var coordinator: HikeIntentCoordinator {
        HikeIntentContext.override ?? appCoordinator
    }
}
