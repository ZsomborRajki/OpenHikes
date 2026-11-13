//
//  CloudKit.swift
//  trail-cells
//
//  The public database, over CloudKit Web Services, with a server-to-server
//  key.
//
//  The app reaches CloudKit through the framework, as whoever is signed in to
//  the phone. A script has nobody signed in, so it signs each request itself:
//  the key is an ECDSA P-256 pair whose public half is entered in the CloudKit
//  Console, under the container's *Tokens & Keys*, and whose private half
//  never leaves the machine that uploads. Apple's reference says a request
//  made with one accesses the public database "as the developer who created
//  the key", which is what lets it write record types only the `reviewer`
//  role may write — see `CommunitySchema`. `whoami` prints the account a key
//  acts as, for checking that against the role's members.
//
//  What is signed is the date, the SHA-256 of the body and the path, joined
//  with colons; the signature and the date travel as headers. Nothing here is
//  specific to trail squares: it is lookup, modify and the three steps an
//  asset takes — ask for a URL, send the bytes, save the receipt on a record.
//

import CryptoKit
import Foundation

struct CloudKitError: Error, CustomStringConvertible {
    var description: String
}

/// The private half of a server-to-server key, and the id the Console gave
/// its public half.
struct ServerKey: Sendable {
    let id: String
    private let key: P256.Signing.PrivateKey

    init(id: String, pemFile: String) throws {
        self.id = id
        do {
            key = try P256.Signing.PrivateKey(
                pemRepresentation: String(contentsOfFile: pemFile, encoding: .utf8)
            )
        } catch {
            throw CloudKitError(description: "\(pemFile) is not a P-256 private key in PEM form: \(error)")
        }
    }

    /// The three headers that make a request this key's.
    func headers(forBody body: Data, subpath: String, at date: Date) throws -> [String: String] {
        let stamp = ISO8601DateFormatter().string(from: date)
        let bodyHash = Data(SHA256.hash(data: body)).base64EncodedString()
        let message = "\(stamp):\(bodyHash):\(subpath)"
        let signature = try key.signature(for: Data(message.utf8)).derRepresentation.base64EncodedString()
        return [
            "X-Apple-CloudKit-Request-KeyID": id,
            "X-Apple-CloudKit-Request-ISO8601Date": stamp,
            "X-Apple-CloudKit-Request-SignatureV1": signature,
        ]
    }
}

/// One container's public database in one environment.
struct PublicDatabase: Sendable {
    static let defaultEndpoint = "https://api.apple-cloudkit.com"
    /// The most operations, names or tokens one request may carry.
    static let batchLimit = 200
    private static let attempts = 4

    var endpoint: String
    var container: String
    var environment: String
    var key: ServerKey

    func subpath(_ operation: String) -> String {
        "/database/1/\(container)/\(environment)/public/\(operation)"
    }
}

// MARK: - The operations

extension PublicDatabase {
    /// What the database holds under each of `names`: its fields, or that it
    /// holds nothing.
    func lookup(_ names: [String], desiredKeys: [String]) async throws -> [String: RecordAnswer] {
        var answers: [String: RecordAnswer] = [:]
        for batch in names.chunked(into: Self.batchLimit) {
            let response: RecordsResponse = try await post(
                "records/lookup",
                LookupRequest(records: batch.map(LookupRequest.Name.init), desiredKeys: desiredKeys)
            )
            for record in response.records {
                guard let name = record.recordName else { continue }
                answers[name] = RecordAnswer(record)
            }
        }
        return answers
    }

    /// Applies `operations`, and answers the ones the server refused.
    func modify(_ operations: [Operation]) async throws -> [String: String] {
        var refused: [String: String] = [:]
        for batch in operations.chunked(into: Self.batchLimit) {
            let response: RecordsResponse = try await post("records/modify", ModifyRequest(operations: batch))
            for record in response.records {
                guard let code = record.serverErrorCode else { continue }
                refused[record.recordName ?? "?"] = "\(code): \(record.reason ?? "no reason given")"
            }
        }
        return refused
    }

    /// Sends `bytes` as the asset one field of one record will hold, and
    /// answers the receipt a modify sets that field to.
    func uploadAsset(_ bytes: Data, to uploadURL: String) async throws -> AssetReceipt {
        guard let url = URL(string: uploadURL) else {
            throw CloudKitError(description: "CloudKit answered an upload URL that is not one: \(uploadURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bytes
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let answer: AssetUploadResponse = try await send(request, describing: "uploading an asset")
        return answer.singleFile
    }

    /// The URLs to send the assets of `fields` to, by record name.
    func uploadURLs(for fields: [TokenRequest.Token]) async throws -> [String: String] {
        var urls: [String: String] = [:]
        for batch in fields.chunked(into: Self.batchLimit) {
            let response: TokenResponse = try await post("assets/upload", TokenRequest(tokens: batch))
            for token in response.tokens {
                urls[token.recordName] = token.url
            }
        }
        return urls
    }

    /// The account this key acts as.
    func caller() async throws -> String {
        let response: CallerResponse = try await send(
            try signed(operation: "users/caller", body: nil),
            describing: "users/caller"
        )
        return response.userRecordName
    }

    /// The bytes behind an asset field's download URL.
    func download(_ asset: AssetValue) async throws -> Data {
        guard let text = asset.downloadURL,
              // The URL carries a `${f}` where a file name may go.
              let url = URL(string: text.replacingOccurrences(of: "${f}", with: "asset"))
        else { throw CloudKitError(description: "an asset came back without a download URL.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudKitError(description: "downloading an asset answered \(response).")
        }
        return data
    }
}

// MARK: - Sending

private extension PublicDatabase {
    func post<Response: Decodable>(_ operation: String, _ body: some Encodable) async throws -> Response {
        try await send(try signed(operation: operation, body: JSONEncoder().encode(body)), describing: operation)
    }

    func signed(operation: String, body: Data?) throws -> URLRequest {
        let subpath = subpath(operation)
        guard let url = URL(string: endpoint + subpath) else {
            throw CloudKitError(description: "\(endpoint + subpath) is not a URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try key.headers(forBody: body ?? Data(), subpath: subpath, at: Date()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sends `request`, again after a pause when the answer is one that asks
    /// for that, and decodes what comes back.
    func send<Response: Decodable>(_ request: URLRequest, describing what: String) async throws -> Response {
        var pause: TimeInterval = 1
        for attempt in 1...Self.attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    return try JSONDecoder().decode(Response.self, from: data)
                }
                let failure = try? JSONDecoder().decode(ServiceFailure.self, from: data)
                guard attempt < Self.attempts, failure?.retryAfter != nil || status >= 500 else {
                    throw CloudKitError(description: Self.explain(failure, status: status, body: data, what: what))
                }
                pause = max(pause, failure?.retryAfter ?? 0)
            } catch let error as URLError where attempt < Self.attempts {
                TrailCellsTool.printError("\(what): \(error.localizedDescription); trying again.")
            }
            try await Task.sleep(for: .seconds(pause))
            pause *= 2
        }
        throw CloudKitError(description: "\(what) did not answer.")
    }

    static func explain(_ failure: ServiceFailure?, status: Int, body: Data, what: String) -> String {
        let code = failure?.serverErrorCode ?? "HTTP \(status)"
        let reason = failure?.reason ?? String(decoding: body.prefix(300), as: UTF8.self)
        let hint = switch code {
        case "AUTHENTICATION_FAILED":
            " Check that the key id is one of this container's server-to-server keys in this "
                + "environment, and that the PEM file is the private half of the public key entered there."
        case "ACCESS_DENIED":
            " The account the key acts as may not write this record type. Run `whoami` and check that "
                + "account is in the role the type's WRITE and CREATE are granted to, in this environment."
        default:
            ""
        }
        return "\(what) failed — \(code): \(reason)\(hint)"
    }
}

// MARK: - The wire

/// What a lookup says about one name.
enum RecordAnswer {
    case found([String: FieldValue])
    case missing
    case failed(String)

    init(_ record: RecordResult) {
        switch record.serverErrorCode {
        case nil:
            self = .found(record.fields ?? [:])
        case "NOT_FOUND":
            self = .missing
        case let code?:
            self = .failed("\(code): \(record.reason ?? "no reason given")")
        }
    }
}

struct RecordsResponse: Decodable {
    var records: [RecordResult]
}

struct RecordResult: Decodable {
    var recordName: String?
    var serverErrorCode: String?
    var reason: String?
    var fields: [String: FieldValue]?
}

/// A field as a lookup answers it: one of the three shapes this tool reads.
enum FieldValue: Decodable {
    case text(String)
    case number(Double)
    case asset(AssetValue)
    case other

    private enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .value) {
            self = .text(text)
        } else if let number = try? container.decode(Double.self, forKey: .value) {
            self = .number(number)
        } else if let asset = try? container.decode(AssetValue.self, forKey: .value) {
            self = .asset(asset)
        } else {
            self = .other
        }
    }
}

struct AssetValue: Decodable {
    var downloadURL: String?
}

struct ServiceFailure: Decodable {
    var serverErrorCode: String?
    var reason: String?
    var retryAfter: Double?
}

struct CallerResponse: Decodable {
    var userRecordName: String
}

struct LookupRequest: Encodable {
    struct Name: Encodable {
        var recordName: String
    }

    var records: [Name]
    var desiredKeys: [String]
}

struct TokenRequest: Encodable {
    struct Token: Encodable {
        var recordType: String
        var recordName: String
        var fieldName: String
    }

    var tokens: [Token]
}

struct TokenResponse: Decodable {
    struct Token: Decodable {
        var recordName: String
        var fieldName: String
        var url: String
    }

    var tokens: [Token]
}

struct AssetUploadResponse: Decodable {
    var singleFile: AssetReceipt
}

/// What the asset store answers an upload with, passed back as the field's
/// value exactly as it came.
struct AssetReceipt: Codable, Sendable {
    var wrappingKey: String?
    var fileChecksum: String
    var receipt: String
    var referenceChecksum: String?
    var size: Int
}

struct ModifyRequest: Encodable {
    var operations: [Operation]
}

struct Operation: Encodable, Sendable {
    /// `forceReplace`, `forceUpdate` and `forceDelete` are the three this
    /// tool sends: it is the only writer of these records, so there is no
    /// other change for a conflict to protect.
    var operationType: String
    var record: Record

    struct Record: Encodable, Sendable {
        var recordType: String?
        var recordName: String
        var fields: [String: Field]?
    }

    enum Field: Encodable, Sendable {
        case text(String)
        case integer(Int64)
        case timestamp(Date)
        case asset(AssetReceipt)

        private enum CodingKeys: String, CodingKey {
            case value, type
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .value)
                try container.encode("STRING", forKey: .type)
            case .integer(let number):
                try container.encode(number, forKey: .value)
                try container.encode("INT64", forKey: .type)
            case .timestamp(let date):
                // Milliseconds since 1970, which is how the service spells a
                // date.
                try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()), forKey: .value)
                try container.encode("TIMESTAMP", forKey: .type)
            case .asset(let receipt):
                try container.encode(receipt, forKey: .value)
                try container.encode("ASSETID", forKey: .type)
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
