//
//  ProcessResourceSample.swift
//  OpenTrails
//
//  The two process-wide numbers a text-only performance run actually needs:
//  how much memory this process is charged for, and how much CPU time it has
//  burned since launch. Sampled at a low rate from a background queue, the
//  second one answers the question a render count cannot — "the app looked
//  idle, but was it?" — because CPU time keeps climbing whether the work is a
//  SwiftUI body, a MapKit redraw, or a timer nobody meant to leave running.
//
//  Deliberately `mach` rather than `ProcessInfo`: `phys_footprint` is the
//  figure the OS itself uses for memory limits and jetsam, and the pairing of
//  `TASK_BASIC_INFO` with `TASK_THREAD_TIMES_INFO` is the only way to get CPU
//  time that includes threads which have already exited — a per-fix task pool
//  is exactly the kind of work that would otherwise vanish from the total.
//

import Darwin
import Foundation

#if DEBUG
nonisolated struct ProcessResourceSample: Sendable {
    /// Bytes of physical memory the OS charges this process for.
    let footprintBytes: UInt64
    /// Total CPU time consumed since launch, across live and exited threads.
    let cpuSeconds: Double

    static func current() -> Self? {
        guard let footprint = footprintBytes(), let cpu = cpuSeconds() else {
            return nil
        }
        return Self(footprintBytes: footprint, cpuSeconds: cpu)
    }

    private static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// `TASK_BASIC_INFO` carries the time of threads that have already
    /// terminated and `TASK_THREAD_TIMES_INFO` the time of those still
    /// running; either one alone under-reports a process that spawns
    /// short-lived work, which is precisely this app's per-fix shape.
    private static func cpuSeconds() -> Double? {
        var basic = task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), rebound, &basicCount)
            }
        }
        guard basicStatus == KERN_SUCCESS else { return nil }

        var threads = task_thread_times_info_data_t()
        var threadCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let threadStatus = withUnsafeMutablePointer(to: &threads) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), rebound, &threadCount)
            }
        }
        guard threadStatus == KERN_SUCCESS else { return nil }

        return seconds(basic.user_time)
            + seconds(basic.system_time)
            + seconds(threads.user_time)
            + seconds(threads.system_time)
    }

    private static func seconds(_ value: time_value_t) -> Double {
        let microsecondsPerSecond = 1_000_000.0
        return Double(value.seconds) + Double(value.microseconds) / microsecondsPerSecond
    }
}
#endif
