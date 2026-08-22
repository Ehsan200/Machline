import Darwin
import Foundation
import HarnessCore

// AgentHarness MCP inspection proxy.
//
// Sits between the CLI and a stdio MCP server, relaying JSON-RPC in both directions unchanged while
// teeing a copy of every message to the inspector socket.
//
// Usage:
//   harness-mcp-proxy --server-name <name> -- <command> [args...]
//   HARNESS_MCP_INSPECTOR_SOCKET=<path>
//
// **This component fails OPEN, deliberately, and that is the opposite of `harness-approve`.**
// The approval helper is a security gate, so silence there means an unapproved command runs and
// every error path must deny. This proxy is an *observability* tool: it makes no security decision,
// and blocking traffic because a debugging socket is unavailable would break the operator's MCP
// servers for no safety gain. So if the inspector is missing, slow, or crashes, relaying continues
// uninterrupted and only the inspection is lost.

let environment = ProcessInfo.processInfo.environment
var arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("harness-mcp-proxy: \(message)\n".utf8))
    exit(64)
}

var serverName = "unknown"
if let index = arguments.firstIndex(of: "--server-name"), index + 1 < arguments.count {
    serverName = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
    fail("expected `-- <command> [args...]`")
}
let command = arguments[separator + 1]
let commandArguments = Array(arguments[(separator + 2)...])

// MARK: - Inspector tee (best effort, never blocking the relay)

final class InspectorTee: @unchecked Sendable {
    private let connection: UnixSocket.Connection?
    private let serverName: String

    init(serverName: String, socketPath: String?) {
        self.serverName = serverName
        // A failed connection is not an error; inspection is simply off for this run.
        connection = socketPath.flatMap { $0.isEmpty ? nil : UnixSocket.Connection(socketPath: $0) }
    }

    func record(_ line: String, direction: MCPTrafficRecord.Direction) {
        guard let connection, connection.isOpen else { return }
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return
        }
        let record = MCPTrafficRecord(
            serverName: serverName, direction: direction, timestamp: Date(), payload: payload)
        guard let encoded = try? record.encoded() else { return }
        // A dropped tee closes the connection; relaying carries on regardless.
        connection.send(encoded)
    }

    func close() {
        connection?.close()
    }
}

let tee = InspectorTee(
    serverName: serverName, socketPath: environment["HARNESS_MCP_INSPECTOR_SOCKET"])

// MARK: - Relay

let child = Process()
child.executableURL = URL(fileURLWithPath: command.contains("/") ? command : "/usr/bin/env")
child.arguments = command.contains("/") ? commandArguments : [command] + commandArguments
child.environment = environment

let toChild = Pipe()
let fromChild = Pipe()
child.standardInput = toChild
child.standardOutput = fromChild
// The server's own logging belongs on our stderr, untouched.
child.standardError = FileHandle.standardError

do {
    try child.run()
} catch {
    fail("could not launch \(command): \(error)")
}

/// Relays newline-delimited JSON, forwarding **before** teeing so inspection never adds latency to
/// the message path.
func relay(
    from source: FileHandle, to destination: FileHandle,
    direction: MCPTrafficRecord.Direction, onEnd: @escaping @Sendable () -> Void
) {
    let queue = DispatchQueue(label: "harness-mcp-proxy.\(direction.rawValue)")
    queue.async {
        var assembler = LineAssembler()
        while true {
            let data = source.availableData
            if data.isEmpty { break }

            // Forward the raw bytes untouched: reserialising JSON could alter key order or number
            // formatting that a server or client depends on.
            do { try destination.write(contentsOf: data) } catch { break }

            if let lines = try? assembler.append(data) {
                for line in lines { tee.record(line, direction: direction) }
            }
        }
        onEnd()
    }
}

let group = DispatchGroup()
group.enter()
group.enter()

relay(
    from: FileHandle.standardInput, to: toChild.fileHandleForWriting,
    direction: .toServer,
    onEnd: {
        try? toChild.fileHandleForWriting.close()
        group.leave()
    })

relay(
    from: fromChild.fileHandleForReading, to: FileHandle.standardOutput,
    direction: .toClient,
    onEnd: { group.leave() })

child.waitUntilExit()
// Give the output relay a moment to drain anything still buffered.
_ = group.wait(timeout: .now() + 2)
tee.close()
exit(child.terminationStatus)
