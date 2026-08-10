import Foundation
import Testing

// Exercises the Claude Code session-restore hook shipped by the hooks installer. The pin is persisted
// shell code that re-runs on every launch until cleared, so what this hook refuses to write matters as
// much as what it writes.
struct ClaudeRestoreHookTests {
    private static var hook: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-claude-restore.sh")
            .path
    }

    private func run(_ action: String, input: String,
                     environment: [String: String] = ["AGTERM_SESSION_ID": "sid"]) throws -> (calls: [String], exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-claude-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let calls = dir.appendingPathComponent("calls")
        let agtermctl = dir.appendingPathComponent("agtermctl")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n"
            .write(to: agtermctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agtermctl.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.hook, action]
        proc.environment = environment.merging(["AGTERMCTL": agtermctl.path, "PATH": "/usr/bin:/bin"]) { a, _ in a }
        let standardInput = Pipe()
        proc.standardInput = standardInput
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        standardInput.fileHandleForWriting.write(Data(input.utf8))
        try standardInput.fileHandleForWriting.close()
        proc.waitUntilExit()

        let logged = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (logged, proc.terminationStatus)
    }

    private let sessionID = "0198cd0f-1a2b-4c3d-8e4f-0123456789ab"

    @Test func sessionStartPinsTheLiveSessionWithPaneAndSocket() throws {
        let result = try run("session-start", input: """
        {"session_id":"\(sessionID)","cwd":"/w","hook_event_name":"SessionStart","source":"startup"}
        """, environment: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/a.sock",
                           "AGTERM_PANE": "right", "AGTERM_PANE_ID": "tok"])
        #expect(result.calls == ["session restore claude --resume \(sessionID) "
            + "--target sid --socket /tmp/a.sock --pane right --pane-id tok"])
        #expect(result.exit == 0)
    }

    @Test func sessionStartReadsAPrettyPrintedPayload() throws {
        let result = try run("session-start", input: """
        {
          "session_id": "\(sessionID)",
          "source": "resume"
        }
        """)
        #expect(result.calls == ["session restore claude --resume \(sessionID) --target sid"])
    }

    @Test func sessionStartLeavesThePinAloneWithoutAUsableID() throws {
        // a bad id would be re-typed on every launch until cleared, so no id is better than a broken one
        for payload in ["{}", #"{"session_id":""}"#, #"{"session_id":"not-a-uuid"}"#,
                        #"{"session_id":"0198cd0f-1a2b-4c3d-8e4f-0123456789zz"}"#] {
            let result = try run("session-start", input: payload)
            #expect(result.calls.isEmpty, "\(payload) should not pin")
            #expect(result.exit == 0)
        }
    }

    @Test func outsideAgtermItDoesNothing() throws {
        let result = try run("session-start", input: #"{"session_id":"\#(sessionID)"}"#, environment: [:])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func sessionEndUnpinsOnlyOnADeliberateExit() throws {
        for reason in ["logout", "prompt_input_exit"] {
            let result = try run("session-end", input: #"{"reason":"\#(reason)"}"#)
            #expect(result.calls == ["session restore --clear --target sid"])
        }
        // `other` is what a killed process reports, and quitting agterm kills it — clearing there would
        // undo the very pin this hook exists to keep
        for payload in [#"{"reason":"other"}"#, #"{"reason":"clear"}"#, "{}"] {
            #expect(try run("session-end", input: payload).calls.isEmpty, "\(payload) should keep the pin")
        }
    }

    @Test func anUnknownActionIsANoOp() throws {
        #expect(try run("wat", input: #"{"session_id":"\#(sessionID)"}"#).calls.isEmpty)
    }
}
