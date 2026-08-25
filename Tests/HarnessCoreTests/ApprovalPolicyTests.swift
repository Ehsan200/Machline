import Foundation
import Testing
@testable import HarnessCore

@Suite("Approval policy and risk classification")
struct ApprovalPolicyTests {

    private func bash(_ command: String, cwd: String = "/work") -> HookPayload {
        HookPayload(
            sessionID: "s", toolName: "Bash",
            toolInput: .object(["command": .string(command)]),
            toolUseID: "toolu_1", cwd: cwd)
    }

    @Test("Prefix and glob rules match commands")
    func ruleMatching() {
        var store = PolicyStore()
        store.add(.allowBashPrefix("git status"))
        store.add(ApprovalRule(toolName: .exact("Bash"), argument: .glob("cargo check*"), effect: .allow))

        #expect(store.evaluate(payload: bash("git status --short"))?.decision.verdict == .allow)
        #expect(store.evaluate(payload: bash("cargo check --all"))?.decision.verdict == .allow)
        #expect(store.evaluate(payload: bash("git push")) == nil)
    }

    /// Adding an allow rule must never widen access past an existing denial, whatever the order in
    /// which the two were created.
    @Test("Deny rules beat allow rules regardless of insertion order")
    func denyWins() {
        var store = PolicyStore()
        store.add(.allowBashPrefix("git"))
        store.add(ApprovalRule(
            toolName: .exact("Bash"), argument: .glob("*--force*"), effect: .deny,
            reason: "Force pushes are blocked."))

        let match = store.evaluate(payload: bash("git push --force origin main"))
        #expect(match?.decision.verdict == .deny)
        #expect(match?.decision.provenance == .denylistRule)
        #expect(match?.decision.reason == "Force pushes are blocked.")
    }

    @Test("Rules can be scoped and cleared by scope")
    func scopedRules() {
        var store = PolicyStore()
        store.add(.allowBashPrefix("ls", scope: .session))
        store.add(.allowBashPrefix("cat", scope: .persistent))
        store.removeAll(scope: .session)

        #expect(store.evaluate(payload: bash("ls -la")) == nil)
        #expect(store.evaluate(payload: bash("cat file")) != nil)
    }

    /// The sheet shows what else a proposed rule would have caught, so a broad pattern reads as
    /// broad before the operator commits to it.
    @Test("A proposed rule previews its own blast radius")
    func blastRadiusPreview() {
        let store = PolicyStore()
        let history = [bash("git status"), bash("git push --force"), bash("npm test")]
        let proposed = ApprovalRule.allowBashPrefix("git")
        let matched = store.wouldAlsoMatch(rule: proposed, among: history)
        #expect(matched.count == 2)
        #expect(matched.contains { $0.bashCommand == "git push --force" })
    }

    @Test("Destructive and privileged commands outrank benign ones")
    func riskLevels() {
        let classifier = RiskClassifier()
        #expect(classifier.assess(command: "rm -rf build").level == .destructive)
        #expect(classifier.assess(command: "sudo launchctl load x").level == .privileged)
        #expect(classifier.assess(command: "curl https://example.com").level == .network)
        #expect(classifier.assess(command: "ls -la").level == .benign)
        #expect(classifier.assess(command: "rm -rf /").recommendsDenyByDefault)
    }

    /// Shell indirection defeats pattern matching, so it is surfaced rather than silently treated
    /// as benign. The classifier is advisory — this is about not overstating confidence.
    @Test("Indirection is flagged rather than assumed benign")
    func indirectionIsFlagged() {
        let classifier = RiskClassifier()
        let assessment = classifier.assess(command: "echo $(cat /etc/passwd)")
        #expect(assessment.level > .benign)
        #expect(assessment.signals.contains("command substitution"))
    }

    @Test("Writes outside the workspace are flagged for non-Bash tools")
    func writeOutsideWorkspace() {
        let classifier = RiskClassifier()
        let inside = HookPayload(
            sessionID: "s", toolName: "Write",
            toolInput: .object(["file_path": .string("/work/src/main.swift")]),
            toolUseID: "t", cwd: "/work")
        let outside = HookPayload(
            sessionID: "s", toolName: "Write",
            toolInput: .object(["file_path": .string("/Users/someone/.ssh/authorized_keys")]),
            toolUseID: "t", cwd: "/work")

        #expect(classifier.assess(payload: inside).level == .privileged)
        #expect(classifier.assess(payload: outside).level == .destructive)
        #expect(classifier.assess(payload: outside).signals.contains("writes outside the workspace"))
    }

    /// The bug this replaced: containment was judged against the payload's `cwd`, so an agent
    /// standing in one package of a monorepo appeared to escape the workspace the moment it edited
    /// a sibling — a destructive banner on an ordinary edit.
    @Test("A sibling-package edit is inside the workspace even when the cwd has drifted")
    func siblingPackageEditIsInsideWorkspace() {
        let classifier = RiskClassifier()
        let workspace = Workspace(roots: [URL(fileURLWithPath: "/repo")])
        let sibling = HookPayload(
            sessionID: "s", toolName: "Edit",
            toolInput: .object(["file_path": .string("/repo/apps/web/src/form.tsx")]),
            toolUseID: "t", cwd: "/repo/apps/api")

        let assessment = classifier.assess(payload: sibling, workspace: workspace)
        #expect(assessment.level == .privileged)
        #expect(!assessment.signals.contains("writes outside the workspace"))
    }

    @Test("A write outside the session's roots is still flagged")
    func writeOutsideSessionRootsIsFlagged() {
        let classifier = RiskClassifier()
        let workspace = Workspace(roots: [URL(fileURLWithPath: "/repo")])
        let escape = HookPayload(
            sessionID: "s", toolName: "Edit",
            toolInput: .object(["file_path": .string("/elsewhere/notes.md")]),
            toolUseID: "t", cwd: "/repo/apps/api")

        #expect(classifier.assess(payload: escape, workspace: workspace)
            .signals.contains("writes outside the workspace"))
    }

    /// A path relative to the cwd resolves before comparison; the old prefix test called every one
    /// of them an escape.
    @Test("A relative path resolves against the cwd before it is judged")
    func relativePathResolvesAgainstCWD() {
        let classifier = RiskClassifier()
        let workspace = Workspace(roots: [URL(fileURLWithPath: "/repo")])
        let relative = HookPayload(
            sessionID: "s", toolName: "Edit",
            toolInput: .object(["file_path": .string("src/form.tsx")]),
            toolUseID: "t", cwd: "/repo/apps/api")
        let walkingOut = HookPayload(
            sessionID: "s", toolName: "Edit",
            toolInput: .object(["file_path": .string("../../../etc/hosts")]),
            toolUseID: "t", cwd: "/repo/apps/api")

        #expect(!classifier.assess(payload: relative, workspace: workspace)
            .signals.contains("writes outside the workspace"))
        #expect(classifier.assess(payload: walkingOut, workspace: workspace)
            .signals.contains("writes outside the workspace"))
    }

    /// A directory handed to the session with `--add-dir` — a dragged attachment, say — is not an
    /// escape, even though it sits outside the project.
    @Test("An --add-dir grant counts as workspace for the signal")
    func additionalDirectoryIsNotAnEscape() {
        let classifier = RiskClassifier()
        let workspace = Workspace(roots: [
            URL(fileURLWithPath: "/repo"), URL(fileURLWithPath: "/grants")
        ])
        let granted = HookPayload(
            sessionID: "s", toolName: "Write",
            toolInput: .object(["file_path": .string("/grants/shot.png")]),
            toolUseID: "t", cwd: "/repo")

        #expect(!classifier.assess(payload: granted, workspace: workspace)
            .signals.contains("writes outside the workspace"))
    }

    /// Probe-verified payload shape; guards against a field rename silently emptying the sheet.
    @Test("The archived hook payload decodes into the sheet's fields")
    func archivedHookPayloadDecodes() throws {
        let url = try #require(Bundle.module.url(
            forResource: "hook_payload", withExtension: "json", subdirectory: "Fixtures"))
        let payload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: url))
        #expect(payload.toolName == "Bash")
        #expect(payload.bashCommand == "echo should-be-blocked")
        #expect(payload.toolUseID.hasPrefix("toolu_"))
        #expect(payload.hookEventName == "PreToolUse")
        #expect(!payload.cwd.isEmpty)
        #expect(payload.summary == "echo should-be-blocked")
    }

    /// A payload with unexpected or missing fields must still yield something we can deny.
    @Test("A degenerate payload still decodes rather than throwing")
    func lenientPayloadDecoding() throws {
        let payload = try JSONDecoder().decode(
            HookPayload.self, from: Data(#"{"tool_name":"Bash"}"#.utf8))
        #expect(payload.toolName == "Bash")
        #expect(payload.hookEventName == "PreToolUse")
        #expect(payload.cwd.isEmpty)
    }
}
