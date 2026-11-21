//
//  VectorTileServerSuites.swift
//  OpenHikesVectorTilesTests
//
//  The suites that script a tile server with `StubTileProtocol`, under one
//  parent so that a file still declares one `@Suite`.
//

import Testing

/// The stub's script is process-wide, and `swift test` runs suites side by
/// side, so the suites that write it are children of one serialized suite:
/// two of them at once would each answer the other's requests.
@Suite("Vector tile server", .serialized)
struct VectorTileServerSuites {}
