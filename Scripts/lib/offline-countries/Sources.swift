//
//  Sources.swift
//  offline-countries
//
//  Where an archive's bytes are read from: a file on this Mac, or an object
//  in the R2 bucket read with HTTP ranges and signed with the bucket's S3
//  keys, so a country is cut out of the planet without the planet ever
//  coming down.
//

import CryptoKit
import Foundation
import Synchronization

protocol RangeSource: Sendable {
    var size: UInt64 { get }
    var name: String { get }
    func read(offset: UInt64, length: UInt64) async throws -> [UInt8]
}

enum SourceError: Error, CustomStringConvertible {
    case missingCredentials(String)
    case http(Int, String)
    case shortRead(expected: UInt64, got: Int)

    var description: String {
        switch self {
        case let .missingCredentials(name): "\(name) is not set: source the R2 keys first"
        case let .http(status, what): "R2 answered \(status) for \(what)"
        case let .shortRead(expected, got): "asked for \(expected) bytes and got \(got)"
        }
    }
}

/// `r2:<key>` for an object in the bucket, anything else for a local file.
func openSource(_ argument: String) async throws -> any RangeSource {
    if argument.hasPrefix("r2:") {
        return try await R2Source(key: String(argument.dropFirst("r2:".count)))
    }
    return try FileSource(url: URL(fileURLWithPath: argument))
}

final class FileSource: RangeSource {
    let size: UInt64
    let name: String
    private let handle: Mutex<FileHandle>

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
        name = url.lastPathComponent
        self.handle = Mutex(handle)
    }

    func read(offset: UInt64, length: UInt64) async throws -> [UInt8] {
        try handle.withLock { handle in
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            guard data.count == Int(length) else { throw SourceError.shortRead(expected: length, got: data.count) }
            return Array(data)
        }
    }
}

/// An object in R2, read through its S3 endpoint with Signature Version 4.
final class R2Source: RangeSource {
    let size: UInt64
    let name: String
    private let url: URL
    private let signer: R2Signer
    private let session: URLSession

    init(key: String) async throws {
        signer = try R2Signer()
        name = key
        url = signer.objectURL(key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        signer.sign(&request)
        let (_, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, let length = http?.expectedContentLength, length > 0 else {
            throw SourceError.http(http?.statusCode ?? 0, key)
        }
        size = UInt64(length)
    }

    func read(offset: UInt64, length: UInt64) async throws -> [UInt8] {
        var attempt = 0
        while true {
            do {
                return try await readOnce(offset: offset, length: length)
            } catch {
                attempt += 1
                guard attempt < 4 else { throw error }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    private func readOnce(offset: UInt64, length: UInt64) async throws -> [UInt8] {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        signer.sign(&request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 206 else { throw SourceError.http(status, "\(name) at \(offset)") }
        guard data.count == Int(length) else { throw SourceError.shortRead(expected: length, got: data.count) }
        return Array(data)
    }
}

/// Signs a request for the bucket named in the environment, as
/// `Scripts/vector-extras.sh` signs its upload with curl.
struct R2Signer: Sendable {
    let account: String
    let bucket: String
    private let keyID: String
    private let secret: String

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw SourceError.missingCredentials(name) }
            return value
        }
        account = try value("R2_ACCOUNT_ID")
        bucket = try value("R2_BUCKET")
        keyID = try value("R2_ACCESS_KEY_ID")
        secret = try value("R2_SECRET_ACCESS_KEY")
    }

    func objectURL(_ key: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://\(account).r2.cloudflarestorage.com/\(bucket)/\(key)")!
    }

    func sign(_ request: inout URLRequest, now: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        let day = String(stamp.prefix(8))
        let payload = "UNSIGNED-PAYLOAD"
        request.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [
            request.httpMethod ?? "GET",
            url.path(percentEncoded: true),
            "",
            "host:\(host)\nx-amz-content-sha256:\(payload)\nx-amz-date:\(stamp)\n",
            signedHeaders,
            payload,
        ].joined(separator: "\n")
        let scope = "\(day)/auto/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))]
            .joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, "auto", "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(keyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The SHA-256 of a whole file, read a few megabytes at a time.
func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return R2Signer.hex(hasher.finalize())
}
