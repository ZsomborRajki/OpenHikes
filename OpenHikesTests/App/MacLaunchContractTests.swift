//
//  MacLaunchContractTests.swift
//  OpenHikesTests
//
//  That the app's code links CoreLocation's Swift overlay weakly.
//
//  An Apple silicon Mac runs the iPad app against macOS's copy of the overlay,
//  which has `CLBackgroundActivitySession` but neither its `Diagnostic` nor
//  `diagnostics`. Linked strongly, dyld refuses the launch there before any
//  code runs. No gate runs on a Mac, so losing `-weak-lswiftCoreLocation` from
//  the app target would show only as a crash report from somebody's Mac (*The
//  Mac* in AGENTS.md). The simulator build carries the same load command, so
//  it is held here, as `InfoPlistContractTests` holds the keys nobody would
//  miss.
//

import Foundation
import MachO
import Testing

@Suite("Mac launch contract")
struct MacLaunchContractTests {
    private static let overlay = "libswiftCoreLocation.dylib"

    /// Every image of the app's own code that names the overlay: the
    /// executable, and in a Debug build `OpenHikes.debug.dylib`, which holds
    /// the code the executable only loads.
    @Test("the app's code loads CoreLocation's Swift overlay weakly")
    func coreLocationOverlayIsWeak() throws {
        let loads = appImages().flatMap(dylibLoads).filter { $0.name.hasSuffix("/\(Self.overlay)") }
        try #require(!loads.isEmpty, "no image of the app names \(Self.overlay)")
        for load in loads {
            #expect(load.command == LC_LOAD_WEAK_DYLIB, "\(load.name) is loaded strongly")
        }
    }

    private func appImages() -> [UnsafePointer<mach_header>] {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "OpenHikes"
        let names: Set = [executable, "\(executable).debug.dylib"]
        return (0..<_dyld_image_count()).compactMap { index in
            guard let header = _dyld_get_image_header(index),
                  let path = _dyld_get_image_name(index).map({ String(cString: $0) })
            else { return nil }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent().path == bundle,
                  names.contains(url.lastPathComponent)
            else { return nil }
            return header
        }
    }

    /// The dylibs an image loads, with the load command that names each.
    private func dylibLoads(of header: UnsafePointer<mach_header>) -> [(command: UInt32, name: String)] {
        var loads: [(command: UInt32, name: String)] = []
        var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_LOAD_DYLIB) || command.cmd == LC_LOAD_WEAK_DYLIB {
                let dylib = cursor.loadUnaligned(as: dylib_command.self)
                let name = (cursor + Int(dylib.dylib.name.offset)).assumingMemoryBound(to: CChar.self)
                loads.append((command.cmd, String(cString: name)))
            }
            cursor += Int(command.cmdsize)
        }
        return loads
    }
}
