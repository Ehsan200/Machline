import Foundation
import Testing
@testable import HarnessCore

/// Loads an archived probe transcript. These are real CLI 2.1.237 output, captured in `probes/`,
/// and they are the contract test suite for the frame schema (README, Runtime).
enum Fixture: String, CaseIterable {
    case plainTurn = "p1"
    case bashToolCall = "p2"
    case subagent = "p3"
    case hookDeny = "p4"
    case hookTimeoutFailOpen = "p5"
    case hookLongWaitDeny = "p6"
    case strictMCPIsolation = "p7"
    case ambientMCPLeak = "p8"

    func lines() throws -> [String] {
        let url = try #require(
            Bundle.module.url(forResource: rawValue, withExtension: "jsonl", subdirectory: "Fixtures"),
            "Missing fixture \(rawValue).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func frames() throws -> [Frame] {
        let decoder = FrameDecoder()
        return try lines().compactMap { line in
            guard case .frame(let frame) = decoder.decode(line: line) else { return nil }
            return frame
        }
    }
}
