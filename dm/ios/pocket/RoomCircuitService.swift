// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation

struct RoomCircuitAppointment: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let starts: Int
    let game: String
    let app: String
    let interested: Int
    let ready: Bool
}

struct RoomCircuitGame: Decodable, Identifiable, Sendable {
    let game: String
    let app: String?
    let name: String
    let zh: String?
    var id: String { game + (app ?? "") }
}

struct RoomCircuitEndpoint: Decodable, Identifiable, Sendable {
    let id: String
    let host: String
    let port: Int
    let transport: String

    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

struct RoomCircuitOptions: Decodable, Sendable {
    let nativeApi: Int?
    let games: [RoomCircuitGame]
    let endpoints: [RoomCircuitEndpoint]
    let readyBefore: Int
    let readyLease: Int
}

struct RoomCircuitRoom: Decodable, Sendable {
    let host: String
    let players: Int
    let max: Int
    let appointmentBound: Bool
    let crossplay: Bool
    let titleConfirmed: Bool
}

struct RoomCircuitReply: Decodable, Sendable {
    let now: Int?
    let rows: [RoomCircuitAppointment]?
    let rooms: [RoomCircuitRoom]?
    let next: Int?
    let created: RoomCircuitAppointment?
    let error: String?
}

enum RoomCircuitFailure: Error, Equatable {
    case origin
    case input
    case capability
    case response(Int, String?)
}

struct RoomCircuitRequest: Encodable {
    let action: String
    let identity: String
    var offset: Int? = nil
    var id: String? = nil
    var starts: Int? = nil
    var game: String? = nil
    var app: String? = nil
}

final class RoomCircuitNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RoomCircuitService: Sendable {
    let origin: URL
    let identity: String
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: RoomCircuitNoRedirects(), delegateQueue: nil)
    }()

    static func parseOrigin(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              let hostname = parts.host?.lowercased(), !hostname.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.percentEncodedPath),
              parts.port.map({ (1...65_535).contains($0) }) ?? true
        else { throw RoomCircuitFailure.origin }

        let scheme = parts.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && localHTTPHost(hostname))
        else { throw RoomCircuitFailure.origin }
        parts.scheme = scheme
        parts.host = hostname
        parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        guard let url = parts.url else { throw RoomCircuitFailure.origin }
        return url
    }

    private static func localHTTPHost(_ host: String) -> Bool {
        if ["localhost", "[::1]", "::1"].contains(host) { return true }
        let ipv4 = host.split(separator: ".", omittingEmptySubsequences: false)
        if ipv4.count == 4 {
            let octets = ipv4.compactMap { UInt8($0) }
            if octets.count == 4 && zip(octets, ipv4).allSatisfy({ String($0) == $1 }) {
                let a = octets[0], b = octets[1]
                return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
            }
        }
        return host.hasSuffix(".local") && host.utf8.allSatisfy { char in
            (48...57).contains(char) || (97...122).contains(char) || char == 46 || char == 45
        }
    }

    static func key(_ origin: URL, _ suffix: String) -> String {
        let hash = SHA256.hash(data: Data(origin.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "roomcircuit.\(hash).\(suffix)"
    }

    static func savedIdentity(for origin: URL, defaults: UserDefaults = .standard) -> String {
        let key = key(origin, "device")
        if let value = defaults.string(forKey: key), hex(value, count: 32),
           value.utf8.contains(where: { $0 != 48 }) { return value }
        let value = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        defaults.set(value, forKey: key)
        return value
    }

    static func hex(_ value: String, count: Int = 16) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 128_000 else {
            throw RoomCircuitFailure.response(0, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RoomCircuitFailure.response(http.statusCode, try? JSONDecoder().decode(RoomCircuitReply.self, from: data).error)
        }
        return data
    }

    func options() async throws -> RoomCircuitOptions {
        let request = URLRequest(url: origin.appending(path: "/api/appointments/options"))
        let options = try JSONDecoder().decode(RoomCircuitOptions.self, from: await fetch(request))
        guard options.nativeApi == 1 else { throw RoomCircuitFailure.capability }
        return options
    }

    func get(_ action: String, id: String? = nil, offset: Int? = nil) async throws -> RoomCircuitReply {
        try await send(.init(action: action, identity: identity, offset: offset, id: id))
    }

    func create(start: Date, game: String, app: String?) async throws -> RoomCircuitReply {
        let lcid = game.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hex(lcid), lcid != "0000000000000000", lcid.lowercased() != "ffffffffffffffff",
              appID.map({ Self.hex($0) }) ?? true
        else { throw RoomCircuitFailure.input }
        return try await send(.init(action: "create", identity: identity, starts: Int(start.timeIntervalSince1970),
                                    game: lcid, app: appID))
    }

    private func send(_ command: RoomCircuitRequest) async throws -> RoomCircuitReply {
        var request = URLRequest(url: origin.appending(path: "/api/appointments/native"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("native-v1", forHTTPHeaderField: "X-RoomCircuit-Client")
        request.httpBody = try JSONEncoder().encode(command)
        let reply = try JSONDecoder().decode(RoomCircuitReply.self, from: await fetch(request))
        if let error = reply.error { throw RoomCircuitFailure.response(200, error) }
        return reply
    }
}
