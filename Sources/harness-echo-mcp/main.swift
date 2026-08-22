import Foundation
import HarnessCore

// A minimal stdio MCP server.
//
// Exists so the MCP hub can be tested against a real JSON-RPC peer rather than a mock, with no
// external dependency. It advertises one read tool and one write tool, which is enough to exercise
// capability classification, tool grants, and traffic inspection. Not a product feature.

func send(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(id: JSONValue, result: JSONValue) {
    send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
}

let toolList = JSONValue.object(["tools": .array([
    .object([
        "name": .string("echo_text"),
        "description": .string("Returns the text it was given."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object(["text": .object(["type": .string("string")])]),
            "required": .array([.string("text")])
        ])
    ]),
    .object([
        "name": .string("write_note"),
        "description": .string("Stores a note, replacing any previous one."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object(["body": .object(["type": .string("string")])]),
            "required": .array([.string("body")])
        ])
    ])
])])

var assembler = LineAssembler()
let decoder = JSONDecoder()

while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    guard let lines = try? assembler.append(chunk) else { continue }

    for line in lines {
        guard let message = try? decoder.decode(JSONValue.self, from: Data(line.utf8)) else { continue }
        let method = message["method"]?.stringValue
        // A message without an id is a notification and takes no reply.
        guard let id = message["id"], id != .null else { continue }

        switch method {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("harness-echo"), "version": .string("1.0.0")
                ])
            ]))

        case "tools/list":
            reply(id: id, result: toolList)

        case "tools/call":
            let arguments = message.value(at: "params", "arguments")
            let text = arguments?["text"]?.stringValue ?? arguments?["body"]?.stringValue ?? ""
            reply(id: id, result: .object([
                "content": .array([.object([
                    "type": .string("text"), "text": .string("ECHO:\(text)")
                ])])
            ]))

        default:
            reply(id: id, result: .object([:]))
        }
    }
}
