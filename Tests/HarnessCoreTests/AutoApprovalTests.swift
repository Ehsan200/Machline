import Foundation
import Testing
@testable import HarnessCore

/// Auto-approval is the one feature here that can let a command run unread, so its edges are
/// pinned: what it covers, what it refuses to cover, and what still overrides it.
struct AutoApprovalTests {

    private let classifier = RiskClassifier()

    private func bash(_ command: String, cwd: String = "/work") -> HookPayload {
        HookPayload(
            sessionID: "s", toolName: "Bash",
            toolInput: .object(["command": .string(command)]),
            toolUseID: "t", cwd: cwd)
    }

    private func edit(path: String, cwd: String = "/work", tool: String = "Edit") -> HookPayload {
        HookPayload(
            sessionID: "s", toolName: tool,
            toolInput: .object(["file_path": .string(path)]),
            toolUseID: "t", cwd: cwd)
    }

    private func decision(_ mode: AutoApproval, _ payload: HookPayload) -> ApprovalDecision? {
        mode.decision(for: payload, assessment: classifier.assess(payload: payload))
    }

    // MARK: Manual

    @Test("Manual mode answers nothing")
    func manualDecidesNothing() {
        #expect(decision(.manual, bash("ls")) == nil)
        #expect(decision(.manual, edit(path: "/work/a.swift")) == nil)
    }

    // MARK: Ceiling

    @Test("A benign command is auto-approved at the benign ceiling")
    func benignCeilingAllowsPlainCommands() {
        let mode = AutoApproval(bashCeiling: .benign)
        #expect(decision(mode, bash("ls -la"))?.verdict == .allow)
        #expect(decision(mode, bash("ls -la"))?.provenance == .autoApproved)
    }

    /// Shell indirection defeats pattern matching, so the classifier escalates it — and the benign
    /// ceiling must therefore not cover it.
    @Test("Piped, chained, and substituted commands are not benign")
    func benignCeilingStopsAtIndirection() {
        let mode = AutoApproval(bashCeiling: .benign)
        #expect(decision(mode, bash("cat x | sh")) == nil)
        #expect(decision(mode, bash("echo $(whoami)")) == nil)
        #expect(decision(mode, bash("make && make install")) == nil)
    }

    @Test("Network commands need the network ceiling")
    func networkNeedsItsCeiling() {
        #expect(decision(AutoApproval(bashCeiling: .benign), bash("curl example.com")) == nil)
        #expect(decision(AutoApproval(bashCeiling: .network), bash("curl example.com"))?.verdict
            == .allow)
    }

    /// The two levels an operator most needs to see are not expressible as a ceiling.
    @Test("Privileged and destructive commands are never auto-approved")
    func riskyCommandsAlwaysAsk() {
        let widest = AutoApproval(bashCeiling: .destructive)
        #expect(widest.bashCeiling == .network)
        #expect(decision(widest, bash("sudo rm -rf /")) == nil)
        #expect(decision(widest, bash("chmod 777 /etc/passwd")) == nil)
    }

    @Test("A ceiling above the cap is clamped, not honoured")
    func ceilingIsClamped() {
        #expect(AutoApproval(bashCeiling: .privileged).bashCeiling == .network)
        #expect(AutoApproval(bashCeiling: .destructive).bashCeiling == .network)
        #expect(AutoApproval(bashCeiling: .benign).bashCeiling == .benign)
    }

    // MARK: Auto mode

    /// The whole point of the preset: local work runs, and nothing leaves the machine unread.
    @Test("Auto mode runs local work and holds everything outward")
    func autoModeRunsLocalWorkOnly() {
        #expect(decision(.auto, bash("swift build"))?.verdict == .allow)
        #expect(decision(.auto, bash("cat x | wc -l"))?.verdict == .allow)
        #expect(decision(.auto, bash("curl https://example.com"))?.verdict == .allow)
        #expect(decision(.auto, edit(path: "/work/src/main.swift"))?.verdict == .allow)

        for outward in [
            "git push origin main",
            "git commit -m 'x'",
            "git tag v1.0.0",
            "npm publish",
            "docker push acme/app:1",
            "gh release create v1",
            "kubectl apply -f deploy.yaml",
            "terraform apply -auto-approve",
            "scp build.zip host:/tmp",
            "rsync -a dist/ host:/srv"
        ] {
            #expect(decision(.auto, bash(outward)) == nil, "\(outward) must still ask")
        }
    }

    /// The holdout is about reversibility, not risk level, so it must survive a ceiling that
    /// otherwise covers the command.
    @Test("The outward holdout outranks the ceiling")
    func outwardHoldoutBeatsTheCeiling() {
        let withHoldout = AutoApproval(bashCeiling: .network, holdsOutwardCommands: true)
        let without = AutoApproval(bashCeiling: .network, holdsOutwardCommands: false)

        #expect(decision(withHoldout, bash("git push")) == nil)
        #expect(decision(without, bash("git push"))?.verdict == .allow)
    }

    /// Auto mode is a preset, not a mode flag: it must be exactly the parts it claims to set, or
    /// the switch in the panel reads back as off the moment anything else is touched.
    @Test("Auto mode is the sum of its stated parts")
    func autoModeIsItsParts() {
        #expect(AutoApproval.auto.bashCeiling == .network)
        #expect(AutoApproval.auto.workspaceFileEdits)
        #expect(AutoApproval.auto.holdsOutwardCommands)
        #expect(AutoApproval.auto.isFullAuto)
        #expect(!AutoApproval.manual.isFullAuto)
        #expect(!AutoApproval(bashCeiling: .network, workspaceFileEdits: true,
                              holdsOutwardCommands: false).isFullAuto)
    }

    /// A setting stored before the holdout existed must come back with the holdout on, not decode
    /// into nothing and silently reset the mode.
    @Test("A setting stored without the holdout decodes with it enabled")
    func storedSettingGainsTheHoldout() throws {
        let stored = Data(#"{"bashCeiling":1,"workspaceFileEdits":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoApproval.self, from: stored)
        #expect(decoded.bashCeiling == .network)
        #expect(decoded.workspaceFileEdits)
        #expect(decoded.holdsOutwardCommands)
    }

    // MARK: File edits

    @Test("An edit inside the workspace is auto-approved when enabled")
    func editInsideWorkspaceIsApproved() {
        let mode = AutoApproval(workspaceFileEdits: true)
        #expect(decision(mode, edit(path: "/work/src/main.swift"))?.verdict == .allow)
    }

    @Test("An edit outside the workspace always asks")
    func editOutsideWorkspaceAsks() {
        let mode = AutoApproval(workspaceFileEdits: true)
        #expect(decision(mode, edit(path: "/etc/hosts")) == nil)
        #expect(decision(mode, edit(path: "/Users/someone/.ssh/config")) == nil)
    }

    /// A relative path with `..` resolves outside the root, and must be caught after resolution
    /// rather than by a prefix test on the raw string.
    @Test("A path escaping the workspace with .. is not inside it")
    func dotDotCannotEscape() {
        let mode = AutoApproval(workspaceFileEdits: true)
        #expect(decision(mode, edit(path: "/work/../etc/hosts")) == nil)
        #expect(decision(mode, edit(path: "../secrets.env")) == nil)
    }

    /// `/work` must not appear to contain `/workspace`.
    @Test("A sibling directory sharing a prefix is not inside the workspace")
    func siblingPrefixIsNotContainment() {
        let mode = AutoApproval(workspaceFileEdits: true)
        #expect(decision(mode, edit(path: "/workspace/other.swift", cwd: "/work")) == nil)
    }

    @Test("An edit payload naming no path asks rather than assuming")
    func unknownEditShapeAsks() {
        let mode = AutoApproval(workspaceFileEdits: true)
        let payload = HookPayload(
            sessionID: "s", toolName: "Edit", toolInput: .object([:]), toolUseID: "t", cwd: "/work")
        #expect(decision(mode, payload) == nil)
    }

    /// Containment is judged against the session's root, not the directory the agent is standing
    /// in — otherwise auto mode prompts for a sibling-package edit it had already agreed to.
    @Test("An edit is auto-approved from a drifted cwd inside the session root")
    func editIsApprovedFromDriftedCWD() {
        let mode = AutoApproval(workspaceFileEdits: true)
        let workspace = SessionWorkspace(roots: [URL(fileURLWithPath: "/repo")])
        let payload = edit(path: "/repo/apps/web/src/form.tsx", cwd: "/repo/apps/api")
        let assessment = classifier.assess(payload: payload, workspace: workspace)
        #expect(mode.decision(for: payload, assessment: assessment, workspace: workspace)?.verdict
            == .allow)
    }

    /// A `--add-dir` grant lets the agent reach a directory. That is not the operator agreeing to
    /// unread writes there, so those still ask.
    @Test("An edit in an --add-dir grant is not auto-approved")
    func editInAdditionalDirectoryAsks() {
        let mode = AutoApproval(workspaceFileEdits: true)
        let workspace = SessionWorkspace(roots: [
            URL(fileURLWithPath: "/repo"), URL(fileURLWithPath: "/grants")
        ])
        let payload = edit(path: "/grants/shot.png", cwd: "/repo")
        let assessment = classifier.assess(payload: payload, workspace: workspace)
        #expect(mode.decision(for: payload, assessment: assessment, workspace: workspace) == nil)
    }

    @Test("Edit auto-approval does not leak into shell commands")
    func editSettingDoesNotCoverBash() {
        let mode = AutoApproval(workspaceFileEdits: true)
        #expect(decision(mode, bash("ls")) == nil)
    }

    // MARK: Precedence

    /// Auto-approval sits behind the rule store, so an explicit deny still wins.
    @Test("A deny rule beats auto-approval")
    func denyRuleWins() {
        var store = PolicyStore()
        store.add(ApprovalRule(
            toolName: .exact("Bash"), argument: .prefix("ls"), effect: .deny))

        let payload = bash("ls -la")
        #expect(store.evaluate(payload: payload)?.decision.verdict == .deny)
        // The broker consults the store first, so the auto decision is never reached.
        #expect(decision(AutoApproval(bashCeiling: .benign), payload)?.verdict == .allow)
    }

    @Test("Auto-approval only ever allows")
    func neverDenies() {
        let modes = [
            AutoApproval(bashCeiling: .benign),
            AutoApproval(bashCeiling: .network),
            AutoApproval(bashCeiling: .network, workspaceFileEdits: true)
        ]
        let payloads = [
            bash("ls"), bash("sudo rm -rf /"), bash("curl x"),
            edit(path: "/work/a"), edit(path: "/etc/hosts")
        ]
        for mode in modes {
            for payload in payloads {
                #expect(decision(mode, payload)?.verdict != .deny)
            }
        }
    }

    @Test("Settings survive a round trip, with the cap reapplied")
    func codableRoundTripClamps() throws {
        let encoded = try JSONEncoder().encode(AutoApproval(bashCeiling: .network,
                                                            workspaceFileEdits: true))
        let decoded = try JSONDecoder().decode(AutoApproval.self, from: encoded)
        #expect(decoded.bashCeiling == .network)
        #expect(decoded.workspaceFileEdits)
        #expect(decoded.isEnabled)
    }
}
