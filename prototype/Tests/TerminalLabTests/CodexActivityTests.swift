import Foundation
import Testing
@testable import TerminalCore

@Test func recognizesOnlyCodexProcessNames() {
    #expect(isCodexProcessName("codex"))
    #expect(isCodexProcessName("codex-tui"))
    #expect(isCodexProcessName("rust-codex"))
    #expect(isCodexProcessName("rust-codex-debug"))
    #expect(!isCodexProcessName("node"))
    #expect(!isCodexProcessName("code"))
    #expect(!isCodexProcessName("codexhelper"))
}

@Test func openCodexIsIdleUntilPromptIsSubmitted() {
    var lifecycle = CodexActivityStateMachine()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    lifecycle.processAppeared()
    #expect(!lifecycle.isRunning)

    lifecycle.submit(processExists: true, at: now)
    lifecycle.processAppeared()
    #expect(lifecycle.isRunning)
}

@Test func staleCompletionCannotHideSubmittedPrompt() {
    var lifecycle = CodexActivityStateMachine()
    let submittedAt = Date(timeIntervalSince1970: 1_800_000_000)
    lifecycle.submit(processExists: true, at: submittedAt)

    lifecycle.consume(payload: [
        "type": "task_complete",
        "completed_at": NSNumber(value: submittedAt.timeIntervalSince1970 - 10)
    ], at: submittedAt)
    #expect(lifecycle.isRunning)

    lifecycle.consume(payload: [
        "type": "task_started",
        "started_at": NSNumber(value: submittedAt.timeIntervalSince1970 + 1)
    ], at: submittedAt.addingTimeInterval(1))
    #expect(lifecycle.isRunning)

    lifecycle.consume(payload: [
        "type": "task_complete",
        "completed_at": NSNumber(value: submittedAt.timeIntervalSince1970 + 3)
    ], at: submittedAt.addingTimeInterval(3))
    #expect(!lifecycle.isRunning)
}

@Test func probeAndTaskStartGracePeriodsExpire() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var probe = CodexActivityStateMachine()
    probe.submit(processExists: false, at: now)
    probe.processAppeared()
    #expect(probe.isRunning)
    probe.expireIfNeeded(at: now.addingTimeInterval(7))
    #expect(probe.isRunning)
    probe.expireIfNeeded(at: now.addingTimeInterval(8))
    #expect(!probe.isRunning)

    var taskStart = CodexActivityStateMachine()
    taskStart.submit(processExists: true, at: now)
    taskStart.expireIfNeeded(at: now.addingTimeInterval(29))
    #expect(taskStart.isRunning)
    taskStart.expireIfNeeded(at: now.addingTimeInterval(30))
    #expect(!taskStart.isRunning)
}

@Test func abortClearsRunningStateAndIgnoresPendingTranscriptEvents() {
    var lifecycle = CodexActivityStateMachine()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    lifecycle.submit(processExists: true, at: now)
    lifecycle.abort()
    lifecycle.consume(payload: [
        "type": "task_started",
        "started_at": NSNumber(value: now.timeIntervalSince1970 + 1)
    ], at: now.addingTimeInterval(1))
    #expect(!lifecycle.isRunning)

    lifecycle.submit(processExists: true, at: now.addingTimeInterval(2))
    #expect(lifecycle.isRunning)
}

@Test func userInputIgnoresEscapeSequencesAndBracketedPasteContents() {
    var tracker = UserInputTracker()
    #expect(tracker.consume([27]) == nil)
    #expect(tracker.consume(Array("[A".utf8)) == nil) // Arrow key sequence.

    #expect(tracker.consume([27, 91, 50]) == nil) // Paste start split across calls.
    let pastedText = Array("00~first line\nsecond line".utf8) + [3, 27, 91, 50]
    #expect(tracker.consume(pastedText) == nil)
    #expect(tracker.isInBracketedPaste)
    #expect(tracker.consume(Array("01~".utf8)) == nil) // Paste end split across calls.
    #expect(!tracker.isInBracketedPaste)

    #expect(tracker.consume([13]) == .submit)
    #expect(tracker.consume([3]) == .abort)
}

@Test func transcriptReaderWaitsForCompleteJSONLines() {
    var reader = TranscriptReader()
    let first = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}".utf8)
    #expect(reader.consume(first).isEmpty)

    let events = reader.consume(Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8))
    #expect(events.map { $0["type"] as? String } == ["task_started", "task_complete"])
}

@Test func currentDirectoryUsesTheRequestedProcessID() async {
    let monitor = CodexActivityMonitor()
    let actual = monitor.currentDirectory(shellPID: Int32(getpid()))
    let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
    #expect(actual == expected)
}

@Test func transcriptMatchingUsesDirectoryAndNearestProcessStart() throws {
    let nonce = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-activity-\(nonce)", isDirectory: true)
    let cwd = root.appendingPathComponent("workspace", isDirectory: true)
    let processStart = ISO8601DateFormatter().date(from: "2026-10-10T15:41:58Z")!
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day], from: processStart)
    let day = root.appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(String(format: "%04d", components.year!))
        .appendingPathComponent(String(format: "%02d", components.month!))
        .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let earlier = day.appendingPathComponent("earlier.jsonl")
    let nearest = day.appendingPathComponent("nearest.jsonl")
    let wrongDirectory = day.appendingPathComponent("other-directory.jsonl")
    let stale = day.appendingPathComponent("stale.jsonl")
    try writeSession(earlier, cwd: cwd, timestamp: "2026-10-10T15:41:50Z")
    try writeSession(nearest, cwd: cwd, timestamp: "2026-10-10T15:42:01Z")
    try writeSession(wrongDirectory, cwd: root, timestamp: "2026-10-10T15:41:58Z")
    try writeSession(stale, cwd: cwd, timestamp: "2026-10-10T15:39:58Z")
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
        ofItemAtPath: stale.path
    )

    let process = CodexProcess(pid: 123, startedAt: processStart, currentDirectory: cwd)
    let match = TranscriptMatcher.find(in: root.appendingPathComponent("sessions"), process: process, now: processStart)
    #expect(match?.resolvingSymlinksInPath().standardizedFileURL == nearest.resolvingSymlinksInPath().standardizedFileURL)
}

private func writeSession(_ url: URL, cwd: URL, timestamp: String) throws {
    let metadata: [String: Any] = [
        "type": "session_meta",
        "payload": ["cwd": cwd.path, "timestamp": timestamp]
    ]
    var line = try JSONSerialization.data(withJSONObject: metadata)
    line.append(10)
    try line.write(to: url)
}
