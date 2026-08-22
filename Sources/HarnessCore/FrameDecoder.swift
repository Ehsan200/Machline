import Foundation

/// Decodes one control-plane line into a `Frame`.
///
/// Permissive by contract (README, Runtime): a line that is not valid JSON yields `.malformed` rather than
/// throwing, so one bad line never tears down a live session. A line that *is* valid JSON always
/// yields a `Frame`, even when its `type` is unrecognised.
public struct FrameDecoder: Sendable {
    public enum Outcome: Sendable {
        case frame(Frame)
        case malformed(line: String, reason: String)
    }

    private let decoder = JSONDecoder()

    public init() {}

    public func decode(line: String) -> Outcome {
        guard let data = line.data(using: .utf8) else {
            return .malformed(line: line, reason: "Line is not valid UTF-8")
        }
        do {
            let value = try decoder.decode(JSONValue.self, from: data)
            guard case .object = value else {
                return .malformed(line: line, reason: "Frame is not a JSON object")
            }
            return .frame(Frame(raw: value))
        } catch {
            return .malformed(line: line, reason: String(describing: error))
        }
    }
}
