//
//  WatchMainActorDelivery.swift
//  OpenHikesWatch
//
//  The bridge a `nonisolated` framework callback uses to reach main-actor
//  state without allocating a task for every delivery.
//
//  A copy of `OpenHikes/General/MainActorDelivery.swift`, which the watch
//  target cannot import — the app is a separate product and the shared package
//  deliberately holds no framework glue. It is copied rather than moved into
//  that package for the reason `WatchGeodesy`'s header gives about
//  `RouteGeometry`: this is called once per GPS fix on each of the two live
//  delegates here, and a cross-module call to a twelve-line function is not
//  reliably inlined.
//
//  The argument for the shape is the app's and is not restated; read it there.
//  What is true on *this* device is the same: `CLLocationManager` and
//  `HKLiveWorkoutBuilder` are both created on the main actor, because the
//  target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so both
//  frameworks deliver to the main thread and take the synchronous path.
//

import Foundation

@inline(__always)
nonisolated func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}
