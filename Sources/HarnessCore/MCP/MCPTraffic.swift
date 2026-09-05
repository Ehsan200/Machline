import Foundation

/// One JSON-RPC message observed by the proxy.
public struct MCPTrafficRecord: Sendable, Hashable, Codable {
    public enum Direction: String, Sendable, Codable {
        /// Client → server.
        case toServer
        /// Server → client.
        case toClient
    }

    public let serverName: String
    public let direction: Direction
    public let timestamp: Date
    /// The JSON-RPC message verbatim.
    public let payload: JSONValue

    public init(serverName: String, direction: Direction, timestamp: Date, payload: JSONValue) {
        self.serverName = serverName
        self.direction = direction
        self.timestamp = timestamp
        self.payload = payload
    }

    public var method: String? { payload["method"]?.stringValue }

    /// JSON-RPC ids may be a string or a number; normalise for pairing.
    public var requestID: String? {
        switch payload["id"] {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(Int(value))
        default: return nil
        }
    }

    public var isNotification: Bool { method != nil && requestID == nil }
    public var isError: Bool { payload["error"] != nil }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(from line: String) throws -> MCPTrafficRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(MCPTrafficRecord.self, from: Data(line.utf8))
    }
}

/// A request paired with its response, as the inspector presents it.
public struct MCPExchange: Sendable, Hashable, Identifiable {
    public var id: String { "\(serverName)#\(requestID)" }
    public let serverName: String
    public let requestID: String
    public let method: String
    public let request: JSONValue
    public var response: JSONValue?
    public let sentAt: Date
    public var respondedAt: Date?

    public var latency: TimeInterval? {
        guard let respondedAt else { return nil }
        return respondedAt.timeIntervalSince(sentAt)
    }

    public var isPending: Bool { response == nil }
    public var isError: Bool { response?["error"] != nil }
}

public enum MCPTrafficEvent: Sendable {
    /// A message arrived. Notifications and unpaired frames surface here too.
    case record(MCPTrafficRecord)
    /// A request was seen, awaiting its response.
    case exchangeStarted(MCPExchange)
    /// The matching response arrived.
    case exchangeCompleted(MCPExchange)
    case failure(String)
}

/// Receives teed JSON-RPC traffic from proxied stdio servers and pairs it into exchanges.
///
/// Observability only. It never sits in the decision path — see `harness-mcp-proxy` for why the
/// proxy keeps relaying even when this is not listening.
public actor MCPInspector {
    public let socketPath: String
    /// Completed exchanges retained for the inspector panel, newest last.
    public private(set) var exchanges: [MCPExchange] = []
    public private(set) var isRunning = false

    private var pending: [String: MCPExchange] = [:]
    /// Responses seen before their request, newest last. See `ingest`.
    private var unmatchedResponses: [(key: String, record: MCPTrafficRecord)] = []
    private var listener: UnixSocket.Listener?
    private var continuation: AsyncStream<MCPTrafficEvent>.Continuation?
    private let historyLimit: Int

    public init(socketPath: String, historyLimit: Int = 2000) {
        self.socketPath = socketPath
        self.historyLimit = historyLimit
    }

    public func start() throws -> AsyncStream<MCPTrafficEvent> {
        guard !isRunning else { throw UnixSocket.Error.bindFailed(errno: EADDRINUSE) }
        let listener = try UnixSocket.Listener(path: socketPath)
        self.listener = listener
        isRunning = true

        let (stream, continuation) = AsyncStream<MCPTrafficEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        let thread = Thread { [weak self] in
            while let descriptor = listener.accept() {
                guard let self else {
                    Darwin.close(descriptor)
                    continue
                }
                // One long-lived connection per proxied server.
                //
                // The lines go through a stream rather than a `Task` per line: unstructured tasks
                // reach the actor in whatever order the scheduler picks, so a response could be
                // ingested before its own request and never pair up.
                let (lines, linesContinuation) = AsyncStream<String>.makeStream(
                    bufferingPolicy: .unbounded)
                Task { [weak self] in
                    for await line in lines {
                        guard let self else { break }
                        await self.ingest(line: line)
                    }
                }
                Thread.detachNewThread {
                    defer {
                        Darwin.close(descriptor)
                        linesContinuation.finish()
                    }
                    while true {
                        guard let line = try? UnixSocket.readLine(
                            descriptor: descriptor,
                            deadline: Date().addingTimeInterval(86_400))
                        else { return }
                        linesContinuation.yield(line)
                    }
                }
            }
        }
        thread.name = "AgentHarness.MCPInspector"
        thread.start()
        return stream
    }

    public func stop() {
        isRunning = false
        listener?.close()
        listener = nil
        continuation?.finish()
        continuation = nil
    }

    public func clearHistory() {
        exchanges.removeAll()
        pending.removeAll()
        unmatchedResponses.removeAll()
    }

    private func ingest(line: String) {
        guard let record = try? MCPTrafficRecord.decode(from: line) else {
            continuation?.yield(.failure("Unparseable inspector record"))
            return
        }
        continuation?.yield(.record(record))

        guard let requestID = record.requestID else { return }  // Notification.
        let key = "\(record.serverName)#\(requestID)"

        switch record.direction {
        case .toServer:
            guard let method = record.method else { return }
            var exchange = MCPExchange(
                serverName: record.serverName, requestID: requestID, method: method,
                request: record.payload, response: nil, sentAt: record.timestamp,
                respondedAt: nil)
            continuation?.yield(.exchangeStarted(exchange))
            // The proxy tees each direction from its own reader, so a fast server's response can
            // reach us first. Pair with it rather than dropping the exchange on the floor.
            if let index = unmatchedResponses.firstIndex(where: { $0.key == key }) {
                let response = unmatchedResponses.remove(at: index).record
                complete(&exchange, with: response)
            } else {
                pending[key] = exchange
            }

        case .toClient:
            guard var exchange = pending.removeValue(forKey: key) else {
                rememberUnmatched(record, key: key)
                return
            }
            complete(&exchange, with: record)
        }
    }

    private func complete(_ exchange: inout MCPExchange, with response: MCPTrafficRecord) {
        exchange.response = response.payload
        exchange.respondedAt = response.timestamp
        exchanges.append(exchange)
        if exchanges.count > historyLimit {
            exchanges.removeFirst(exchanges.count - historyLimit)
        }
        continuation?.yield(.exchangeCompleted(exchange))
    }

    /// Holds a response whose request has not arrived yet.
    ///
    /// Bounded, and deliberately small: an unmatched response is either about to be paired within
    /// microseconds, or belongs to a request made before the inspector was listening and never
    /// will be. Neither case is worth remembering for long.
    private func rememberUnmatched(_ record: MCPTrafficRecord, key: String) {
        unmatchedResponses.append((key: key, record: record))
        if unmatchedResponses.count > 64 {
            unmatchedResponses.removeFirst(unmatchedResponses.count - 64)
        }
    }
}
