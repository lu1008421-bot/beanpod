import Foundation
import Testing
@testable import BeanKit

@Test func generatesValidDistinctTokens() {
    let a = MCPHTTPPolicy.generateToken()
    let b = MCPHTTPPolicy.generateToken()
    #expect(a.count == 64)
    #expect(b.count == 64)
    #expect(a != b)
    #expect(a.unicodeScalars.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
    #expect(MCPHTTPPolicy.isValidTokenFormat(a))
    #expect(!MCPHTTPPolicy.isValidTokenFormat(""))
    #expect(!MCPHTTPPolicy.isValidTokenFormat("short-token"))
    #expect(!MCPHTTPPolicy.isValidTokenFormat("has space 1234567890"))
    #expect(!MCPHTTPPolicy.isValidTokenFormat("line\nbreak1234567890"))
}

@Test func constantTimeEqualsMatchesExactStringsOnly() {
    let token = "0123456789abcdef0123456789abcdef"
    #expect(MCPHTTPPolicy.constantTimeEquals(token, token))
    #expect(!MCPHTTPPolicy.constantTimeEquals(token, "0123456789abcdef0123456789abcde0"))
    #expect(!MCPHTTPPolicy.constantTimeEquals(token, token + "0"))
    #expect(!MCPHTTPPolicy.constantTimeEquals("", token))
}

@Test func parsesValidRequestHeadsIncludingIPv6AndQueryToken() {
    let head1 = [
        "POST /mcp HTTP/1.1",
        "Host: 127.0.0.1:8791",
        "Content-Type: application/json",
        "Content-Length: 42",
        "Authorization: Bearer abcdef0123456789",
    ].joined(separator: "\r\n")
    guard case .ok(let req1) = MCPHTTPPolicy.parseRequestHead(head1) else {
        Issue.record("Expected valid parse for IPv4 POST /mcp")
        return
    }
    #expect(req1.method == "POST")
    #expect(req1.path == "/mcp")
    #expect(req1.contentLength == 42)
    #expect(req1.headers["host"] == "127.0.0.1:8791")
    #expect(MCPHTTPPolicy.extractPresentedToken(from: req1) == "abcdef0123456789")

    let head2 = [
        "POST /mcp?token=querytoken123456 HTTP/1.1",
        "Host: [::1]:8791",
        "Content-Type: application/json; charset=utf-8",
    ].joined(separator: "\r\n")
    guard case .ok(let req2) = MCPHTTPPolicy.parseRequestHead(head2) else {
        Issue.record("Expected valid parse for IPv6 query token")
        return
    }
    #expect(req2.path == "/mcp")
    #expect(req2.queryToken == "querytoken123456")
    #expect(req2.headers["host"] == "[::1]:8791")
    #expect(req2.contentLength == 0)
    #expect(MCPHTTPPolicy.extractPresentedToken(from: req2) == "querytoken123456")
}

@Test func rejectsMalformedOrOversizedRequestHeads() {
    for badLength in ["", "-1", "abc", "12abc"] {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Length: \(badLength)"
        guard case .error(let status, _) = MCPHTTPPolicy.parseRequestHead(raw) else {
            Issue.record("Expected 400 error for Content-Length: '\(badLength)'")
            return
        }
        #expect(status == "400 Bad Request")
    }

    let tooBig = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Length: \(MCPHTTPPolicy.maxBodyBytes + 1)"
    #expect(MCPHTTPPolicy.parseRequestHead(tooBig) == .error(status: "413 Payload Too Large", message: "payload too large"))

    let chunked = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nTransfer-Encoding: chunked"
    #expect(MCPHTTPPolicy.parseRequestHead(chunked) == .error(status: "501 Not Implemented", message: "transfer-encoding not supported"))

    let dupLen = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Length: 5\r\nContent-Length: 10"
    guard case .error(let dupStatus, _) = MCPHTTPPolicy.parseRequestHead(dupLen) else {
        Issue.record("Expected 400 error for duplicate Content-Length")
        return
    }
    #expect(dupStatus == "400 Bad Request")
}

@Test func validatesLocalHostOriginMethodContentTypeAndToken() {
    let secret = MCPHTTPPolicy.generateToken()
    let port: UInt16 = 8791

    func check(_ raw: String) -> MCPHTTPDecision {
        guard case .ok(let req) = MCPHTTPPolicy.parseRequestHead(raw) else {
            Issue.record("Unexpected head parse failure for:\n\(raw)")
            return .reject(status: "500", message: "parse", extraHeaders: [])
        }
        return MCPHTTPPolicy.validate(req, port: port, expectedToken: secret)
    }

    // Valid POST /mcp with Bearer
    #expect(check("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Type: application/json\r\nAuthorization: Bearer \(secret)") == .mcp)
    // Valid POST /mcp?token=... with charset
    #expect(check("POST /mcp?token=\(secret) HTTP/1.1\r\nHost: localhost:8791\r\nContent-Type: application/json; charset=utf-8") == .mcp)
    // Valid GET /health with Bearer and query token
    #expect(check("GET /health HTTP/1.1\r\nHost: [::1]:8791\r\nAuthorization: bearer \(secret)") == .health)
    #expect(check("GET /health?token=\(secret) HTTP/1.1\r\nHost: 127.0.0.1") == .health)

    // Missing or wrong token
    #expect(check("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Type: application/json")
            == .reject(status: "401 Unauthorized", message: "unauthorized", extraHeaders: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer realm=\"beanpod\"")]))
    #expect(check("GET /health HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nAuthorization: Bearer wrongtoken1234567890")
            == .reject(status: "401 Unauthorized", message: "unauthorized", extraHeaders: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer realm=\"beanpod\"")]))

    // Any Origin header rejected
    for origin in ["https://evil.example", "http://localhost:3000", "null"] {
        #expect(check("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nOrigin: \(origin)\r\nContent-Type: application/json\r\nAuthorization: Bearer \(secret)")
                == .reject(status: "403 Forbidden", message: "cross-origin requests are not allowed", extraHeaders: []))
    }

    // OPTIONS preflight rejected
    #expect(check("OPTIONS /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791")
            == .reject(status: "403 Forbidden", message: "cors preflight disabled", extraHeaders: []))

    // DNS rebinding / wrong host / wrong port / missing host
    for badHost in ["evil.example:8791", "127.0.0.1.evil.com:8791", "127.0.0.1:9999", "0.0.0.0:8791"] {
        #expect(check("POST /mcp HTTP/1.1\r\nHost: \(badHost)\r\nContent-Type: application/json\r\nAuthorization: Bearer \(secret)")
                == .reject(status: "403 Forbidden", message: "forbidden host", extraHeaders: []))
    }
    #expect(check("POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(secret)")
            == .reject(status: "400 Bad Request", message: "missing host", extraHeaders: []))

    // Content-Type, path, and method enforcement
    #expect(check("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nContent-Type: text/plain\r\nAuthorization: Bearer \(secret)")
            == .reject(status: "415 Unsupported Media Type", message: "use application/json", extraHeaders: []))
    #expect(check("GET /other HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nAuthorization: Bearer \(secret)")
            == .reject(status: "404 Not Found", message: "not found", extraHeaders: []))
    #expect(check("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nAuthorization: Bearer \(secret)")
            == .reject(status: "405 Method Not Allowed", message: "use POST", extraHeaders: [HTTPHeader(name: "Allow", value: "POST")]))
    #expect(check("POST /health HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nAuthorization: Bearer \(secret)")
            == .reject(status: "405 Method Not Allowed", message: "use GET", extraHeaders: [HTTPHeader(name: "Allow", value: "GET")]))
}

@Test func responseFormatterOmitsCorsAndAddsSecurityHeaders() {
    let raw = MCPHTTPPolicy.formatResponse(
        status: "401 Unauthorized",
        body: MCPHTTPPolicy.errorBody("unauthorized"),
        extraHeaders: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer realm=\"beanpod\"")]
    )
    let text = String(decoding: raw, as: UTF8.self)
    #expect(!text.localizedCaseInsensitiveContains("Access-Control-Allow-Origin"))
    #expect(!text.localizedCaseInsensitiveContains("Access-Control-Allow-Headers"))
    #expect(!text.localizedCaseInsensitiveContains("Access-Control-Allow-Methods"))
    #expect(text.contains("Cache-Control: no-store\r\n"))
    #expect(text.contains("X-Content-Type-Options: nosniff\r\n"))
    #expect(text.contains("WWW-Authenticate: Bearer realm=\"beanpod\"\r\n"))
    #expect(text.contains("{\"error\":\"unauthorized\"}"))
}
