//
//  PowerStateMonitor.swift
//  OpenHikes
//
//  The two signals the system gives an app about how much energy it should be
//  spending, in a form the rest of the app can act on rather than merely
//  display.
//
//  Both were already reachable — `ProcessInfo` has had them for years — and
//  the app already read one of them, once, to put a sentence on the recording
//  screen. What was missing is that nothing *changed behaviour* because of
//  them: a hike started in Low Power Mode ran the GPS exactly as hard as one
//  started at full charge, and a device throttling itself in the sun kept
//  being asked for the most expensive positioning mode there is.
//
//  Two consumers, with different needs, which is why the state is published
//  twice:
//
//  * The recording screen and ``HikeRecorder`` are on the main actor and want
//    observation, so ``state`` is `@Observable`. Changes are rare — a handful
//    per walk — so nothing here is a render-isolation hazard.
//  * ``TileCache`` decides whether to open a connection from a background
//    queue, per tile, and cannot hop to the main actor to ask. So every change
//    is also pushed into ``PowerState/current``, a lock-guarded snapshot any
//    thread can read without touching `ProcessInfo` on a hot path.
//

import Foundation
import Observation
import Synchronization

nonisolated struct PowerState: Equatable, Sendable {
    var isLowPowerModeEnabled = false
    var thermalState: ProcessInfo.ThermalState = .nominal

    init(
        isLowPowerModeEnabled: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    /// What the system reports right now. Reading `ProcessInfo` is a real
    /// call, not a field access, which is why the snapshot below exists rather
    /// than every caller doing this.
    static func reported() -> Self {
        let info = ProcessInfo.processInfo
        return Self(
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            thermalState: info.thermalState
        )
    }

    /// The last state a ``PowerStateMonitor`` observed, readable from any
    /// thread. Defaults to "nothing is asking for less", so code that runs
    /// before a monitor exists behaves exactly as it did before this file.
    private static let snapshot = Mutex(Self())

    static var current: Self { snapshot.withLock { $0 } }

    static func publish(_ state: Self) {
        snapshot.withLock { $0 = state }
    }

    /// True when the device is asking the app to spend less — either because
    /// the user turned on Low Power Mode or because it is throttling.
    var isConserving: Bool {
        isLowPowerModeEnabled || RecordingEnergyPolicy.conserves(thermalState)
    }

    var signpostDetail: String {
        "lowPower=\(isLowPowerModeEnabled ? 1 : 0) thermal=\(thermalState.diagnosticName)"
    }
}

extension ProcessInfo.ThermalState {
    nonisolated var diagnosticName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

@Observable
final class PowerStateMonitor {
    private(set) var state: PowerState

    /// Injectable so a test can drive a thermal escalation without a hot
    /// device, and a Low Power Mode transition without Settings — neither of
    /// which a simulator can produce on demand.
    @ObservationIgnored private let read: @Sendable () -> PowerState
    @ObservationIgnored nonisolated private let center: NotificationCenter
    /// Unregistered by the `isolated deinit` below, which is what lets this be
    /// a plain isolated property: the last release may happen anywhere, but
    /// SE-0371 hops the deinit back to this object's actor before it runs, so
    /// `tokens` is only ever touched from the actor that wrote it.
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init(
        read: @escaping @Sendable () -> PowerState = { PowerState.reported() },
        notificationCenter: NotificationCenter = .default,
        observesNotifications: Bool = true
    ) {
        self.read = read
        center = notificationCenter
        let initial = read()
        state = initial
        PowerState.publish(initial)
        guard observesNotifications else { return }
        observe(.NSProcessInfoPowerStateDidChange)
        observe(ProcessInfo.thermalStateDidChangeNotification)
    }

    isolated deinit {
        for token in tokens { center.removeObserver(token) }
    }

    /// Re-reads the system and republishes if anything moved. Public because
    /// it is also the whole of the test seam: a test hands in a mutable
    /// reader and calls this.
    @discardableResult func refresh() -> Bool {
        let next = read()
        guard next != state else { return false }
        state = next
        PowerState.publish(next)
        RenderSignpost.mark("PowerStateChanged", next.signpostDetail)
        return true
    }

    private func observe(_ name: Notification.Name) {
        // Both notifications are posted on an arbitrary queue, so the hop to
        // the main actor is explicit rather than relying on `queue:` — which
        // would silently deliver on whichever thread posted if `nil` were
        // ever passed.
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        tokens.append(token)
    }
}
