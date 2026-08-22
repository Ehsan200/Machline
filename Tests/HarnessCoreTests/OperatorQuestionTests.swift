import Foundation
import Testing
@testable import HarnessCore

@Suite("Operator questions")
struct OperatorQuestionTests {

    private func payload(toolName: String = AskUserQuestion.toolName, input: String) throws -> HookPayload {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
        return HookPayload(
            sessionID: "s", toolName: toolName, toolInput: value,
            toolUseID: "tu-1", cwd: "/tmp")
    }

    @Test("A single-select question parses with its options and their descriptions")
    func singleSelect() throws {
        let request = try payload(input: #"""
        {"questions":[{"header":"Storage","question":"Where should uploads go?","multiSelect":false,
        "options":[{"label":"S3","description":"Cheap, eventually consistent"},{"label":"Disk"}]}]}
        """#)

        let questions = AskUserQuestion.questions(in: request)
        #expect(questions.count == 1)
        #expect(questions[0].header == "Storage")
        #expect(questions[0].question == "Where should uploads go?")
        #expect(questions[0].allowsMultiple == false)
        #expect(questions[0].options.map(\.label) == ["S3", "Disk"])
        #expect(questions[0].options[0].detail == "Cheap, eventually consistent")
        #expect(questions[0].options[1].detail == nil)
    }

    @Test("Several questions keep their order, and multi-select is carried through")
    func multipleQuestions() throws {
        let request = try payload(input: #"""
        {"questions":[
          {"question":"First?","options":[{"label":"a"}]},
          {"question":"Second?","multiSelect":true,"options":[{"label":"b"},{"label":"c"}]}]}
        """#)

        let questions = AskUserQuestion.questions(in: request)
        #expect(questions.map(\.question) == ["First?", "Second?"])
        #expect(questions.map(\.index) == [0, 1])
        #expect(questions[1].allowsMultiple)
    }

    /// The shapes are probe-derived, not contractual, so a drifted request must still be
    /// answerable rather than presenting an empty sheet.
    @Test("Shorthand and bare-string options still parse")
    func lenientShapes() throws {
        let shorthand = try payload(input: #"{"question":"Proceed?","options":["yes","no"]}"#)
        let questions = AskUserQuestion.questions(in: shorthand)
        #expect(questions.count == 1)
        #expect(questions[0].options.map(\.label) == ["yes", "no"])
    }

    @Test("A question with no options is input, not a broken request")
    func freeTextQuestion() throws {
        let request = try payload(input: #"{"questions":[{"question":"Which branch?"}]}"#)
        let questions = AskUserQuestion.questions(in: request)
        #expect(questions.count == 1)
        #expect(questions[0].options.isEmpty)
    }

    @Test("Another tool's payload carries no questions")
    func otherToolsAreNotQuestions() throws {
        let request = try payload(toolName: "Bash", input: #"{"command":"ls"}"#)
        #expect(AskUserQuestion.isQuestion(request) == false)
        #expect(AskUserQuestion.questions(in: request).isEmpty)
    }

    /// The answer travels back as a denial's reason, so the wording has to read as a reply. An
    /// agent that reads it as a refusal re-plans around a question it did get an answer to.
    @Test("The result reads as an answer and names every question")
    func resultWording() throws {
        let request = try payload(input: #"""
        {"questions":[{"header":"Storage","question":"Where?","options":[{"label":"S3"}]},
                      {"question":"Which region?","options":[]}]}
        """#)
        let questions = AskUserQuestion.questions(in: request)

        let text = AskUserQuestion.result(for: [
            .init(question: questions[0], chosen: ["S3"], note: ""),
            .init(question: questions[1], chosen: [], note: "eu-west-1")
        ])

        #expect(text.contains("Storage: S3"))
        #expect(text.contains("Which region?: eu-west-1"))
        #expect(text.contains("not run"))
    }

    @Test("A chosen option and a typed note are both delivered")
    func choiceAndNote() throws {
        let request = try payload(input: #"{"questions":[{"question":"Where?","options":[{"label":"S3"}]}]}"#)
        let questions = AskUserQuestion.questions(in: request)
        let text = AskUserQuestion.result(for: [
            .init(question: questions[0], chosen: ["S3"], note: "but only for images")
        ])
        #expect(text.contains("S3 — but only for images"))
    }

    @Test("Skipping says so rather than sending an empty answer")
    func skipped() {
        let text = AskUserQuestion.result(for: [])
        #expect(text.contains("without answering"))
    }

    @Test("The question tool is gated, so it reaches the operator at all")
    func questionToolIsMatched() {
        #expect(ApprovalHookInstaller.defaultMatchers.contains(AskUserQuestion.toolName))
    }
}
