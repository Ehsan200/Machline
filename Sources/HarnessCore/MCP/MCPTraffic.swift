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
                Thread.detachNewThread { [weak self] in
                    defer { Darwin.close(descriptor) }
                    while true {
                        guard let line = try? UnixSocket.readLine(
                            descriptor: descriptor,
                            deadline: Date().addingTimeInterval(86_400))
                        else { return }
                        guard let self else { return }
                        Task { await self.ingest(line: line) }
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
            let exchange = MCPExchange(
                serverName: record.serverName, requestID: requestID, method: method,
                request: record.payload, response: nil, sentAt: record.timestamp,
                respondedAt: nil)
            pending[key] = exchange
            continuation?.yield(.exchangeStarted(exchange))

        case .toClient:
            guard var exchange = pending.removeValue(forKey: key) else { return }
            exchange.response = record.payload
            exchange.respondedAt = record.timestamp
            exchanges.append(exchange)
            if exchanges.count > historyLimit {
                exchanges.removeFirst(exchanges.count - historyLimit)
            }
            continuation?.yield(.exchangeCompleted(exchange))
        }
    }
}
