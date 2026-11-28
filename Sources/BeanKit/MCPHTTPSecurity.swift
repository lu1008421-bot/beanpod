import Foundation
import Security

public struct HTTPHeader: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ParsedHTTPRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    public let path: String
    public let queryToken: String?
    public let headers: [String: String]
    public let contentLength: Int

    public init(method: String, target: String, path: String, queryToken: String?, headers: [String: String], contentLength: Int) {
        self.method = method
        self.target = target
        self.path = path
        self.queryToken = queryToken
        self.headers = headers
        self.contentLength = contentLength
    }
}

public enum HTTPHeadParseResult: Sendable, Equatable {
    case ok(ParsedHTTPRequest)
    case error(status: String, message: String)
}

public enum MCPHTTPDecision: Sendable, Equatable {
    case health
    case mcp
    case reject(status: String, message: String, extraHeaders: [HTTPHeader])
}

/// 本机 HTTP MCP 服务的安全策略：只允许回环 Host、拒绝跨域与预检、强制令牌鉴权、限制请求体与响应头。
public enum MCPHTTPPolicy: Sendable {
    public static let minimumTokenLength = 16
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 8 * 1024 * 1024

    private static let singleValueHeaders: Set<String> = [
        "host", "content-length", "content-type", "authorization", "origin", "transfer-encoding",
    ]

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices {
                bytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidTokenFormat(_ token: String) -> Bool {
        guard token.count >= minimumTokenLength else { return false }
        return token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    public static func parseRequestHead(_ rawHead: String) -> HTTPHeadParseResult {
        let lines = rawHead.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .error(status: "400 Bad Request", message: "bad request line")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
              parts[1].hasPrefix("/"),
              parts[2].hasPrefix("HTTP/") else {
            return .error(status: "400 Bad Request", message: "bad request line")
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard !target.contains(where: \.isWhitespace),
              let components = URLComponents(string: "http://127.0.0.1" + target) else {
            return .error(status: "400 Bad Request", message: "bad request target")
        }
        let path = components.path
        let tokenItems = (components.queryItems ?? []).filter { $0.name == "token" }
        if tokenItems.count > 1 {
            return .error(status: "400 Bad Request", message: "duplicate token")
        }
        let queryToken = tokenItems.first?.value.flatMap { $0.isEmpty ? nil : $0 }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                return .error(status: "400 Bad Request", message: "malformed header")
            }
            let rawName = line[..<colon]
            guard !rawName.isEmpty, !rawName.contains(where: \.isWhitespace) else {
                return .error(status: "400 Bad Request", message: "malformed header")
            }
            let name = String(rawName).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                if singleValueHeaders.contains(name) {
                    return .error(status: "400 Bad Request", message: "duplicate \(name)")
                }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil {
            return .error(status: "501 Not Implemented", message: "transfer-encoding not supported")
        }

        let contentLength: Int
        if let rawLen = headers["content-length"] {
            guard !rawLen.isEmpty,
                  rawLen.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let parsed = Int(rawLen),
                  parsed >= 0 else {
                return .error(status: "400 Bad Request", message: "invalid content-length")
            }
            guard parsed <= maxBodyBytes else {
                return .error(status: "413 Payload Too Large", message: "payload too large")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        return .ok(ParsedHTTPRequest(
            method: method,
            target: target,
            path: path,
            queryToken: queryToken,
            headers: headers,
            contentLength: contentLength
        ))
    }

    public static func isAllowedLocalHost(_ host: String, port: UInt16) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = [
            "127.0.0.1",
            "127.0.0.1:\(port)",
            "localhost",
            "localhost:\(port)",
            "[::1]",
            "[::1]:\(port)",
        ]
        return allowed.contains(normalized)
    }

    public static func extractPresentedToken(from request: ParsedHTTPRequest) -> String? {
        if let auth = request.headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            let token = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }
        return request.queryToken
    }

    public static func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    public static func validate(_ request: ParsedHTTPRequest, port: UInt16, expectedToken: String) -> MCPHTTPDecision {
        guard let host = request.headers["host"] else {
            return .reject(status: "400 Bad Request", message: "missing host", extraHeaders: [])
        }
        guard isAllowedLocalHost(host, port: port) else {
            return .reject(status: "403 Forbidden", message: "forbidden host", extraHeaders: [])
        }
        if request.headers["origin"] != nil {
            return .reject(status: "403 Forbidden", message: "cross-origin requests are not allowed", extraHeaders: [])
        }
        if request.method == "OPTIONS" {
            return .reject(status: "403 Forbidden", message: "cors preflight disabled", extraHeaders: [])
        }

        func isAuthorized() -> Bool {
            guard isValidTokenFormat(expectedToken),
                  let presented = extractPresentedToken(from: request) else {
                return false
            }
            return constantTimeEquals(presented, expectedToken)
        }

        switch request.path {
        case "/health":
            guard request.method == "GET" else {
                return .reject(status: "405 Method Not Allowed", message: "use GET", extraHeaders: [HTTPHeader(name: "Allow", value: "GET")])
            }
            guard isAuthorized() else {
                return .reject(status: "401 Unauthorized", message: "unauthorized", extraHeaders: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer realm=\"beanpod\"")])
            }
            return .health
        case "/mcp":
            guard request.method == "POST" else {
                return .reject(status: "405 Method Not Allowed", message: "use POST", extraHeaders: [HTTPHeader(name: "Allow", value: "POST")])
            }
            guard isJSONContentType(request.headers["content-type"]) else {
                return .reject(status: "415 Unsupported Media Type", message: "use application/json", extraHeaders: [])
            }
            guard isAuthorized() else {
                return .reject(status: "401 Unauthorized", message: "unauthorized", extraHeaders: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer realm=\"beanpod\"")])
            }
            return .mcp
        default:
            return .reject(status: "404 Not Found", message: "not found", extraHeaders: [])
        }
    }

    public static func formatResponse(
        status: String,
        body: Data,
        contentType: String = "application/json",
        extraHeaders: [HTTPHeader] = []
    ) -> Data {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
        ]
        for header in extraHeaders {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("Connection: close")
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(body)
        return out
    }

    public static func errorBody(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{\"error\":\"error\"}".utf8)
    }
}
