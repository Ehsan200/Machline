import Foundation
import Testing
@testable import HarnessCore

@Suite("Frame decoding against archived CLI transcripts")
struct FrameDecodingTests {

    /// stdout is *mostly* JSONL, not strictly. A real capture contains an MCP client library log
    /// line written straight to stdout, so the decoder's `.malformed` path is exercised on day one
    /// and must never be fatal.
    @Test("Frame lines decode; stray non-JSON output is tolerated", arguments: Fixture.allCases)
    func allLinesDecode(fixture: Fixture) throws {
        let decoder = FrameDecoder()
        var malformed: [String] = []
        for line in try fixture.lines() {
            if case .malformed(let line, _) = decoder.decode(line: line) { malformed.append(line) }
        }
        switch fixture {
        case .ambientMCPLeak:
            #expect(malformed.count == 1)
            #expect(malformed.first?.contains("does not advertise tools capability") == true)
        default:
            #expect(malformed.isEmpty, "Unexpected malformed lines: \(malformed)")
        }
    }

    /// The stray stdout line above, decoded in isolation: it must degrade to `.malformed` rather
    /// than throwing or aborting the surrounding stream.
    @Test("A library log line on stdout does not kill the stream")
    func strayLogLineIsSurvivable() {
        let decoder = FrameDecoder()
        let stray = "Client.listTools() called but server does not advertise tools capability - returning empty list"
        guard case .malformed(let line, _) = decoder.decode(line: stray) else {
            Issue.record("Expected the stray log line to be reported as malformed")
            return
        }
        #expect(line == stray)
    }

    @Test("Every frame carries session_id and uuid")
    func frameInvariants() throws {
        for fixture in Fixture.allCases {
            for frame in try fixture.frames() {
                #expect(frame.sessionID != nil, "\(fixture.rawValue): \(frame.type) lacks session_id")
                #expect(frame.uuid != nil, "\(fixture.rawValue): \(frame.type) lacks uuid")
            }
        }
    }

    /// `system/init` is **not** reliably the first frame: `p2` leads with `rate_limit_event`.
    /// The supervisor must locate the handshake by matching on it, never by position.
    @Test("system/init carries the negotiated session capabilities, wherever it lands")
    func sessionInitHandshake() throws {
        for fixture in Fixture.allCases {
            let frames = try fixture.frames()
            let inits = frames.compactMap { frame -> SessionInit? in
                guard case .sessionInit(let payload) = frame.kind else { return nil }
                return payload
            }
            #expect(!inits.isEmpty, "\(fixture.rawValue) should carry a handshake")
        }

        let frames = try Fixture.bashToolCall.frames()
        #expect(frames.first?.type == "rate_limit_event",
                "Regression guard: init is not positionally first in this transcript")
        let payload = try #require(frames.compactMap { frame -> SessionInit? in
            guard case .sessionInit(let payload) = frame.kind else { return nil }
            return payload
        }.first)
        #expect(payload.claudeCodeVersion == "2.1.237")
        #expect(payload.model?.contains("haiku") == true)
        #expect(payload.tools.contains("Bash"))
        #expect(payload.cwd != nil)
    }

    @Test("Unknown frame types survive decoding with their payload intact")
    func unknownFramesPreserved() {
        let decoder = FrameDecoder()
        let line = #"{"type":"future_frame_type","session_id":"s","uuid":"u","novel_field":{"a":1}}"#
        guard case .frame(let frame) = decoder.decode(line: line) else {
            Issue.record("Unknown frame type should still decode")
            return
        }
        #expect(frame.kind == .unknown)
        #expect(frame.type == "future_frame_type")
        #expect(frame.raw.value(at: "novel_field", "a")?.intValue == 1)
    }

    @Test("Malformed lines are reported, not thrown")
    func malformedLine() {
        let decoder = FrameDecoder()
        guard case .malformed(_, let reason) = decoder.decode(line: "{not json") else {
            Issue.record("Expected malformed outcome")
            return
        }
        #expect(!reason.isEmpty)

        guard case .malformed = decoder.decode(line: "[1,2,3]") else {
            Issue.record("A non-object JSON value is not a frame")
            return
        }
    }

    @Test("Assistant frames arrive one per content block, grouped by message id")
    func assistantFramesGroupByMessageID() throws {
        let frames = try Fixture.plainTurn.frames()
        let assistantMessages = frames.compactMap { frame -> AssistantMessage? in
            guard case .assistant(let message) = frame.kind else { return nil }
            return message
        }
        #expect(assistantMessages.count == 2, "Expected a thinking frame and a text frame")
        let ids = Set(assistantMessages.map(\.id))
        #expect(ids.count == 1, "Both frames belong to one assistant message")
        #expect(assistantMessages[0].content.first?.blockType == "thinking")
        #expect(assistantMessages[1].content.first?.blockType == "text")
    }

    @Test("rate_limit_event is decoded")
    func rateLimitEvent() throws {
        let frames = try Fixture.plainTurn.frames()
        let rateLimit = frames.compactMap { frame -> RateLimitInfo? in
            guard case .rateLimit(let info) = frame.kind else { return nil }
            return info
        }.first
        let info = try #require(rateLimit, "No rate_limit_event frame found")
        #expect(info.status == "allowed")
        #expect(info.rateLimitType == "five_hour")
    }

    @Test("High-frequency frames are flagged for coalescing")
    func highFrequencyFrames() throws {
        let frames = try Fixture.bashToolCall.frames()
        let noisy = frames.filter(\.isHighFrequency).count
        #expect(noisy > 20, "Probe emitted \(noisy) high-frequency frames; UI must coalesce")
    }

    /// `system/init` is a capability *snapshot*, re-emitted when the tool set changes — not a
    /// one-shot handshake. In `p3` a second init arrives mid-session once ambient MCP servers
    /// finish connecting, growing the tool list from 1 to ~250. The tool drawer must rebuild on
    /// every init, and per-agent grants must be re-evaluated against the newest one.
    @Test("system/init is re-emitted when capabilities change")
    func initIsReEmittedOnCapabilityChange() throws {
        let inits = try Fixture.subagent.frames().compactMap { frame -> SessionInit? in
            guard case .sessionInit(let payload) = frame.kind else { return nil }
            return payload
        }
        #expect(inits.count == 2, "Expected a second capability snapshot")
        #expect(inits[0].tools == ["Task"])
        #expect(inits[1].tools.count > inits[0].tools.count)
        #expect(inits[1].tools.contains { $0.hasPrefix("mcp__") })
    }

    /// Evidence for README, Runtime Finding 4. `p8` ran with `--setting-sources ""` and no strict flag;
    /// `p7` added `--strict-mcp-config`. Only the latter is isolated.
    @Test("Only --strict-mcp-config isolates a session from ambient MCP servers")
    func strictMCPConfigIsolatesSession() throws {
        func serverCount(_ fixture: Fixture) throws -> Int {
            try fixture.frames().compactMap { frame -> SessionInit? in
                guard case .sessionInit(let payload) = frame.kind else { return nil }
                return payload
            }.last?.mcpServers.count ?? 0
        }
        #expect(try serverCount(.strictMCPIsolation) == 0)
        #expect(try serverCount(.ambientMCPLeak) == 9,
                "Regression guard: settings isolation alone leaks ambient MCP servers")
    }
}