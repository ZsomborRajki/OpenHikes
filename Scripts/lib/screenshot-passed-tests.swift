#!/usr/bin/env swift
//
// Only a completed, passing test may supply an upload frame. A process exit
// of 65 also covers ordinary assertions, so it cannot discard its passing
// neighbors. Read the structured result rather than Xcode's printed summary.

import Foundation

struct TestNode: Decodable {
    let nodeType: String
    let nodeIdentifier: String?
    let result: String?
    let children: [TestNode]?
}

struct TestTree: Decodable {
    let testNodes: [TestNode]
}

func collect(_ node: TestNode, into results: inout [String: [String]]) {
    if node.nodeType == "Test Case", let identifier = node.nodeIdentifier {
        results[identifier, default: []].append(node.result ?? "unknown")
    }
    for child in node.children ?? [] { collect(child, into: &results) }
}

do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let tree = try JSONDecoder().decode(TestTree.self, from: data)
    var results: [String: [String]] = [:]
    for node in tree.testNodes { collect(node, into: &results) }
    for (identifier, outcomes) in results.sorted(by: { $0.key < $1.key })
    where outcomes.allSatisfy({ $0 == "Passed" }) {
        print(identifier)
    }
} catch {
    FileHandle.standardError.write(Data("Could not read screenshot test results: \(error)\n".utf8))
    exit(1)
}
