import Foundation
import Testing
@testable import HarnessCore

@Suite("MCP inspection proxy")
struct MCPProxyTests {

    /// Drives a proxied server over stdio, the same way the CLI does.
    final class ProxiedServer {
        let process = Process()
        private let toProxy = Pipe()
        private let fromProxy = Pipe()
        private var assembler = LineAssembler()
        private var buffered: [String] = []

        init(serverName: String, inspectorSocketPath: String?) throws {
            process.executableURL = MCPConfigurationTests.proxyURL
            process.arguments = [
                "--server-name", serverName,
                "--", MCPConfigurationTests.echoServerURL.path
            ]
            var environment = ProcessInfo.processInfo.environment
            if let inspectorSocketPath {
                environment["HARNESS_MCP_INSPECTOR_SOCKET"] = inspectorSocketPath
            } else {
                environment.removeValue(forKey: "HARNESS_MCP_INSPECTOR_SOCKET")
            }
            process.environment = environment
            process.standardInput = toProxy
            process.standardOutput = fromProxy
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func send(id: Int, method: String, params: JSONValue = .object([:])) throws {
            let message = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(id),
                "method": .string(method), "params": params
            ])
            var data = try JSONEncoder().encode(message)
            data.append(UInt8(ascii: "\n"))
            try toProxy.fileHandleForWriting.write(contentsOf: data)
        }

        /// Reads one JSON-RPC line, blocking until it arrives or the peer closes.
        func receive() throws -> JSONValue? {
            while buffered.isEmpty {
                let chunk = fromProxy.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffered += try assembler.append(chunk)
            }
            let line = buffered.removeFirst()
            return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        }

        func finish() {
            try? toProxy.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    static func socketPath() -> String {
        "/tmp/ah-mcp-\(UUID().uuidString.prefix(8)).sock"
    }

    /// The proxy must be transparent: whatever the server answers is what the client sees.
    @Test("Traffic is relayed unchanged in both directions", .timeLimit(.minutes(1)))
    func relaysFaithfully() throws {
        let server = try ProxiedServer(serverName: "echo", inspectorSocketPath: nil)
        defer { server.finish() }

        try server.send(id: 1, method: "initialize")
        let initialize = try #require(try server.receive())
        #expect(initialize.value(at: "result", "serverInfo", "name")?.stringValue == "harness-echo")

        try server.send(id: 2, method: "tools/list")
        let tools = try #require(try server.receive())
        let names = tools.value(at: "result", "tools")?.arrayValue?
            .compactMap { $0["name"]?.stringValue }
        #expect(names == ["echo_text", "write_note"])

        try server.send(id: 3, method: "tools/call", params: .object([
            "name": .string("echo_text"),
            "arguments": .object(["text": .string("through the proxy")])
        ]))
        let call = try #require(try server.receive())
        #expect(call.value(at: "result", "content")?[0]?["text"]?.stringValue
            == "ECHO:through the proxy")
    }

    /// **Deliberately the opposite of `harness-approve`.** The proxy makes no security decision, so
    /// an unavailable inspector must cost inspection only — never the operator's MCP server. If this
    /// test ever starts failing, the fix is in the proxy, not here.
    @Test("An unavailable inspector does not interrupt the relay", .timeLimit(.minutes(1)))
    func failsOpenWhenInspectorMissing() throws {
        let server = try ProxiedServer(
            serverName: "echo", inspectorSocketPath: "/tmp/ah-mcp-nonexistent-\(UUID().uuidString.prefix(6)).sock")
        defer { server.finish() }

        try server.send(id: 1, method: "initialize")
        let response = try #require(try server.receive())
        #expect(response.value(at: "result", "serverInfo", "name")?.stringValue == "harness-echo")
    }

    @Test("Observed traffic is paired into exchanges with latency", .timeLimit(.minutes(1)))
    func capturesExchanges() async throws {
        let inspector = MCPInspector(socketPath: Self.socketPath())
        let events = try await inspector.start()
        defer { Task { await inspector.stop() } }

        let collected = TrafficCollector()
        let collecting = Task {
            for await event in events {
                if case .exchangeCompleted(let exchange) = event { collected.append(exchange) }
            }
        }
        defer { collecting.cancel() }

        let server = try ProxiedServer(
            serverName: "echo", inspectorSocketPath: await inspector.socketPath)
        try server.send(id: 1, method: "initialize")
        _ = try server.receive()
        try server.send(id: 2, method: "tools/call", params: .object([
            "name": .string("echo_text"),
            "arguments": .object(["text": .string("inspect me")])
        ]))
        _ = try server.receive()
        server.finish()

        try await collected.waitForMethods(["initialize", "tools/call"], timeout: 60)
        let exchanges = collected.values

        let initialize = try #require(exchanges.first { $0.method == "initialize" })
        #expect(initialize.serverName == "echo")
        #expect(!initialize.isPending)
        #expect(!initialize.isError)
        #expect((initialize.latency ?? -1) >= 0)

        let call = try #require(exchanges.first { $0.method == "tools/call" })
        #expect(call.request.value(at: "params", "arguments", "text")?.stringValue == "inspect me")
        #expect(call.response?.value(at: "result", "content")?[0]?["text"]?.stringValue
            == "ECHO:inspect me")
    }

    @Test("Records classify direction, notifications, and errors")
    func recordClassification() throws {
        let request = MCPTrafficRecord(
            serverName: "echo", direction: .toServer, timestamp: Date(),
            payload: .object([
                "jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/list")
            ]))
        #expect(request.requestID == "7", "Numeric ids normalise to strings for pairing")
        #expect(request.method == "tools/list")
        #expect(!request.isNotification)

        let notification = MCPTrafficRecord(
            serverName: "echo", direction: .toServer, timestamp: Date(),
            payload: .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        #expect(notification.isNotification)
        #expect(notification.requestID == nil)

        let failure = MCPTrafficRecord(
            serverName: "echo", direction: .toClient, timestamp: Date(),
            payload: .object([
                "jsonrpc": .string("2.0"), "id": .string("abc"),
                "error": .object(["code": .int(-32601)])
            ]))
        #expect(failure.isError)
        #expect(failure.requestID == "abc", "String ids are supported too")

        // Records survive the wire encoding.
        #expect(try MCPTrafficRecord.decode(from: request.encoded()).method == "tools/list")
    }
}

/// Collects exchanges from the inspector's stream across threads.
final class TrafficCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MCPExchange] = []

    var values: [MCPExchange] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ exchange: MCPExchange) {
        lock.lock(); storage.append(exchange); lock.unlock()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) async throws {
        try await wait(timeout: timeout) { $0.count >= count }
    }

    /// Waits for the exchanges the test actually names.
    ///
    /// Counting was the wrong condition: the pairing is asynchronous, so two exchanges having
    /// arrived is no guarantee that *these* two have. On an unloaded machine they were always the
    /// same two; under load the test read the collection a beat early and failed on a `nil` that
    /// was about to be filled in.
    func waitForMethods(_ methods: [String], timeout: TimeInterval) async throws {
        try await wait(timeout: timeout) { exchanges in
            methods.allSatisfy { method in exchanges.contains { $0.method == method } }
        }
    }

    private func wait(
        timeout: TimeInterval, until condition: ([MCPExchange]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(values), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
