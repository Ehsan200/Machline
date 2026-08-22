import Foundation
import Testing
@testable import HarnessCore

@Suite("Line reassembly from chunked pipe reads")
struct LineAssemblerTests {

    @Test("Complete lines pass straight through")
    func wholeLines() throws {
        var assembler = LineAssembler()
        let lines = try assembler.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(lines == ["{\"a\":1}", "{\"b\":2}"])
    }

    /// Pipe reads land wherever the OS puts them. A frame split across two reads must not surface
    /// until it is complete.
    @Test("A frame split across chunks is withheld until terminated")
    func splitAcrossChunks() throws {
        var assembler = LineAssembler()
        #expect(try assembler.append(Data("{\"typ".utf8)).isEmpty)
        #expect(try assembler.append(Data("e\":\"user\"}".utf8)).isEmpty)
        #expect(try assembler.append(Data("\n".utf8)) == ["{\"type\":\"user\"}"])
    }

    /// Decoding each chunk as UTF-8 on arrival would corrupt any multi-byte character straddling a
    /// read boundary. Buffering as bytes and decoding whole lines avoids it.
    @Test("Multi-byte characters split mid-sequence survive")
    func splitMultiByteCharacter() throws {
        var assembler = LineAssembler()
        let payload = Array("{\"t\":\"→ ✅ café\"}".utf8)
        let split = payload.count / 2
        #expect(try assembler.append(Data(payload[..<split])).isEmpty)
        let lines = try assembler.append(Data(payload[split...] + [UInt8(ascii: "\n")]))
        #expect(lines == ["{\"t\":\"→ ✅ café\"}"])
    }

    @Test("Blank lines and CRLF are tolerated")
    func blankAndCRLF() throws {
        var assembler = LineAssembler()
        let lines = try assembler.append(Data("{\"a\":1}\r\n\n\n{\"b\":2}\n".utf8))
        #expect(lines == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test("Unterminated trailing content is recovered at EOF")
    func flushTrailing() throws {
        var assembler = LineAssembler()
        _ = try assembler.append(Data("{\"a\":1}\n{\"partial\"".utf8))
        #expect(assembler.flush() == "{\"partial\"")
        #expect(assembler.flush() == nil)
    }

    @Test("A runaway unterminated stream is bounded")
    func overflowIsBounded() {
        var assembler = LineAssembler(maximumLineLength: 64)
        #expect(throws: LineAssembler.Overflow.self) {
            _ = try assembler.append(Data(repeating: UInt8(ascii: "x"), count: 128))
        }
    }

    @Test("A full transcript replays identically when fed one byte at a time")
    func byteAtATimeMatchesWholeFile() throws {
        let expected = try Fixture.subagent.lines()
        var assembler = LineAssembler()
        var actual: [String] = []
        for byte in Array(expected.joined(separator: "\n").utf8) + [UInt8(ascii: "\n")] {
            actual += try assembler.append(Data([byte]))
        }
        #expect(actual == expected)
    }
}
