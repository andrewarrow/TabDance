import Darwin
import Foundation

/// Reports whether Codex is handling the most recently submitted prompt in a shell.
/// All process and transcript inspection runs on this actor, away from AppKit's main actor.
public actor CodexActivityMonitor {
    public init() {}

    public func noteUserInput(_ bytes: [UInt8], shellPID: Int32) {
        guard shellPID > 0 else { return }
        var session = sessions[shellPID] ?? MonitorSession()
        guard let event = session.input.consume(bytes) else {
            sessions[shellPID] = session
            return
        }
        switch event {
        case .abort:
            session.lifecycle.abort()
            sessions[shellPID] = session
        case .submit:
            let now = Date()
            let process = processForShell(shellPID, now: now)
            if let process { session.setProcess(process) }
            session.lifecycle.submit(processExists: process != nil, at: now)
            if process != nil { session.lastProcessSeen = now }
            sessions[shellPID] = session
        }
    }

    public func activity(shellPID: Int32) -> Bool {
        guard shellPID > 0 else { return false }
        let now = Date()
        let process = processForShell(shellPID, now: now)
        var session = sessions[shellPID] ?? MonitorSession()

        if let process {
            session.setProcess(process)
            session.lastProcessSeen = now
            session.lifecycle.processAppeared()
            if session.transcriptPath == nil, session.nextTranscriptLookup <= now {
                session.transcriptPath = TranscriptMatcher.find(for: process, now: now)
                session.nextTranscriptLookup = now.addingTimeInterval(2)
            }
            if let path = session.transcriptPath {
                let events = session.transcript.readNewEvents(at: path)
                for payload in events {
                    session.lifecycle.consume(payload: payload, at: now)
                }
            }
        } else if session.lastProcessSeen.map({ now.timeIntervalSince($0) > ActivityTiming.processMissingGrace }) ?? true {
            session.lifecycle.processMissing(at: now)
        }

        session.lifecycle.expireIfNeeded(at: now)
        sessions[shellPID] = session
        return session.lifecycle.isRunning
    }

    /// Returns the shell process's current working directory when macOS permits inspection.
    public nonisolated func currentDirectory(shellPID: Int32) -> String? {
        guard shellPID > 0 else { return nil }
        return processCurrentDirectory(pid_t(shellPID))?.path
    }

    private var sessions: [Int32: MonitorSession] = [:]
    private var processSnapshot = ProcessSnapshot(processes: [:])
    private var processSnapshotAt = Date.distantPast

    private func processForShell(_ shellPID: Int32, now: Date) -> CodexProcess? {
        if now.timeIntervalSince(processSnapshotAt) >= 1 {
            processSnapshot = ProcessSnapshot.read()
            processSnapshotAt = now
        }
        return processSnapshot.codexDescendant(of: pid_t(shellPID))
    }
}

private enum ActivityTiming {
    static let promptProbeGrace: TimeInterval = 8
    static let taskStartGrace: TimeInterval = 30
    static let processMissingGrace: TimeInterval = 2
    static let eventTimeSkew: TimeInterval = 2
    static let sessionStartWindow: TimeInterval = 60
    static let transcriptReadLimit = 256 * 1024
    static let metadataReadLimit = 8 * 1024
}

private struct MonitorSession {
    var processID: pid_t?
    var processStartedAt: Date?
    var transcriptPath: URL?
    var nextTranscriptLookup = Date.distantPast
    var transcript = TranscriptReader()
    var lifecycle = CodexActivityStateMachine()
    var lastProcessSeen: Date?
    var input = UserInputTracker()

    mutating func setProcess(_ process: CodexProcess) {
        guard processID != process.pid || processStartedAt != process.startedAt else { return }
        processID = process.pid
        processStartedAt = process.startedAt
        transcriptPath = nil
        nextTranscriptLookup = .distantPast
        transcript = TranscriptReader()
    }
}

enum UserInputEvent: Equatable {
    case submit
    case abort
}

struct UserInputTracker {
    private static let bracketedPasteStart: [UInt8] = [27, 91, 50, 48, 48, 126] // ESC [ 2 0 0 ~
    private static let bracketedPasteEnd: [UInt8] = [27, 91, 50, 48, 49, 126] // ESC [ 2 0 1 ~

    private(set) var isInBracketedPaste = false
    private var pendingEscapeBytes: [UInt8] = []

    mutating func consume(_ bytes: [UInt8]) -> UserInputEvent? {
        var latestEvent: UserInputEvent?
        for byte in bytes {
            if isInBracketedPaste {
                consumePasteByte(byte)
            } else {
                consumeInputByte(byte, latestEvent: &latestEvent)
            }
        }
        return latestEvent
    }

    private mutating func consumeInputByte(_ byte: UInt8, latestEvent: inout UserInputEvent?) {
        guard !pendingEscapeBytes.isEmpty else {
            if byte == 27 {
                pendingEscapeBytes = [byte]
            } else {
                recordInput(byte, latestEvent: &latestEvent)
            }
            return
        }

        let candidate = pendingEscapeBytes + [byte]
        if candidate == Self.bracketedPasteStart {
            pendingEscapeBytes.removeAll(keepingCapacity: true)
            isInBracketedPaste = true
        } else if Self.bracketedPasteStart.starts(with: candidate) {
            pendingEscapeBytes = candidate
        } else {
            pendingEscapeBytes.removeAll(keepingCapacity: true)
            // The ESC begins an escape sequence. Ignore it, then reprocess the
            // remaining bytes so a following real Enter or Ctrl-C still counts.
            for trailingByte in candidate.dropFirst() {
                consumeInputByte(trailingByte, latestEvent: &latestEvent)
            }
        }
    }

    private mutating func consumePasteByte(_ byte: UInt8) {
        guard !pendingEscapeBytes.isEmpty else {
            if byte == 27 { pendingEscapeBytes = [byte] }
            return
        }

        let candidate = pendingEscapeBytes + [byte]
        if candidate == Self.bracketedPasteEnd {
            pendingEscapeBytes.removeAll(keepingCapacity: true)
            isInBracketedPaste = false
        } else if Self.bracketedPasteEnd.starts(with: candidate) {
            pendingEscapeBytes = candidate
        } else {
            pendingEscapeBytes = byte == 27 ? [byte] : []
        }
    }

    private func recordInput(_ byte: UInt8, latestEvent: inout UserInputEvent?) {
        switch byte {
        case 3: latestEvent = .abort
        case 10, 13: latestEvent = .submit
        default: break
        }
    }
}

struct CodexActivityStateMachine {
    private(set) var isRunning = false
    private(set) var submittedAt: Date?
    private var submissionDeadline: Date?
    private var ignoresTranscriptUntilNextSubmission = false

    mutating func submit(processExists: Bool, at now: Date) {
        ignoresTranscriptUntilNextSubmission = false
        isRunning = processExists
        submittedAt = now
        submissionDeadline = now.addingTimeInterval(
            processExists ? ActivityTiming.taskStartGrace : ActivityTiming.promptProbeGrace
        )
    }

    mutating func consume(payload: [String: Any], at _: Date) {
        guard !ignoresTranscriptUntilNextSubmission else { return }
        guard eventBelongsToSubmittedPrompt(payload) else { return }
        guard let eventType = payload["type"] as? String else { return }
        switch eventType {
        case "task_started":
            submissionDeadline = nil
            isRunning = true
        case "task_complete", "turn_aborted":
            finish()
        default:
            break
        }
    }

    mutating func processMissing(at now: Date) {
        if submissionDeadline == nil { finish() }
        expireIfNeeded(at: now)
    }

    mutating func processAppeared() {
        if submissionDeadline != nil { isRunning = true }
    }

    mutating func abort() {
        finish()
        ignoresTranscriptUntilNextSubmission = true
    }

    mutating func expireIfNeeded(at now: Date) {
        if let deadline = submissionDeadline, deadline <= now { finish() }
    }

    private mutating func finish() {
        isRunning = false
        submissionDeadline = nil
        submittedAt = nil
    }

    private func eventBelongsToSubmittedPrompt(_ payload: [String: Any]) -> Bool {
        guard let submittedAt else { return true }
        guard let timestamp = payload["started_at"] as? NSNumber
                ?? payload["completed_at"] as? NSNumber else {
            return submissionDeadline == nil
        }
        let eventDate = Date(timeIntervalSince1970: timestamp.doubleValue)
        return eventDate.addingTimeInterval(ActivityTiming.eventTimeSkew) >= submittedAt
    }
}

struct TranscriptReader {
    private(set) var offset: UInt64 = 0
    private var pending = Data()
    private var discardingOversizedLine = false

    mutating func readNewEvents(at url: URL) -> [[String: Any]] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else { return [] }
        if fileSize.uint64Value < offset {
            offset = 0
            pending.removeAll(keepingCapacity: true)
            discardingOversizedLine = false
        }
        guard fileSize.uint64Value > offset,
              let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: ActivityTiming.transcriptReadLimit), !data.isEmpty else {
                return []
            }
            offset += UInt64(data.count)
            return consume(data)
        } catch {
            return []
        }
    }

    mutating func consume(_ data: Data) -> [[String: Any]] {
        var events: [[String: Any]] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let newline = data[cursor...].firstIndex(of: 10) else {
                let remainder = data[cursor...]
                if discardingOversizedLine { return events }
                if pending.count + remainder.count > ActivityTiming.transcriptReadLimit {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                } else {
                    pending.append(contentsOf: remainder)
                }
                return events
            }

            let segment = data[cursor..<newline]
            cursor = data.index(after: newline)
            if discardingOversizedLine {
                discardingOversizedLine = false
                pending.removeAll(keepingCapacity: true)
                continue
            }
            guard pending.count + segment.count <= ActivityTiming.transcriptReadLimit else {
                pending.removeAll(keepingCapacity: true)
                continue
            }
            pending.append(contentsOf: segment)
            if let envelope = try? JSONSerialization.jsonObject(with: pending) as? [String: Any],
               envelope["type"] as? String == "event_msg",
               let payload = envelope["payload"] as? [String: Any] {
                events.append(payload)
            }
            pending.removeAll(keepingCapacity: true)
        }
        return events
    }
}

struct CodexProcess {
    let pid: pid_t
    let startedAt: Date
    let currentDirectory: URL
}

private struct ProcessRecord {
    let parentID: pid_t
    let name: String
    let arguments: [String]
    let startedAt: Date
}

private struct ProcessSnapshot {
    let processes: [pid_t: ProcessRecord]

    static func read() -> ProcessSnapshot {
        let requestedSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requestedSize > 0 else { return ProcessSnapshot(processes: [:]) }
        let capacity = Int(requestedSize) / MemoryLayout<pid_t>.size + 1
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualSize = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard actualSize > 0 else { return ProcessSnapshot(processes: [:]) }

        var result: [pid_t: ProcessRecord] = [:]
        let count = min(Int(actualSize) / MemoryLayout<pid_t>.size, pids.count)
        for pid in pids.prefix(count) where pid > 0 {
            var bsd = proc_bsdinfo()
            let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard readSize == MemoryLayout<proc_bsdinfo>.size else { continue }
            let name = processName(pid).lowercased()
            let arguments = (name == "node" || isCodexProcessName(name)) ? processArguments(pid) : []
            let startedAt = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000)
            result[pid] = ProcessRecord(parentID: pid_t(bsd.pbi_ppid), name: name, arguments: arguments, startedAt: startedAt)
        }
        return ProcessSnapshot(processes: result)
    }

    func codexDescendant(of rootPID: pid_t) -> CodexProcess? {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in processes { children[info.parentID, default: []].append(pid) }
        var pending = children[rootPID] ?? []
        var launcher: CodexProcess?
        while let pid = pending.popLast() {
            guard let info = processes[pid] else { continue }
            let native = isCodexProcessName(info.name)
            let isLauncher = info.arguments.contains { argument in
                let name = URL(fileURLWithPath: argument).lastPathComponent.lowercased()
                return name == "codex" || name == "codex.js"
            }
            if native || isLauncher, let directory = processCurrentDirectory(pid) {
                let process = CodexProcess(pid: pid, startedAt: info.startedAt, currentDirectory: directory)
                if native { return process }
                if launcher == nil { launcher = process }
            }
            pending.append(contentsOf: children[pid] ?? [])
        }
        return launcher
    }
}

func isCodexProcessName(_ name: String) -> Bool {
    name == "codex" || name.hasPrefix("codex-") || name == "rust-codex" || name.hasPrefix("rust-codex-")
}

private func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let size = buffer.withUnsafeMutableBufferPointer { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
    guard size > 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func processCurrentDirectory(_ pid: pid_t) -> URL? {
    var paths = proc_vnodepathinfo()
    let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard size == MemoryLayout<proc_vnodepathinfo>.size else { return nil }
    let pathBytes = paths.pvi_cdir.vip_path
    let path = withUnsafePointer(to: pathBytes) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pathBytes) / MemoryLayout<CChar>.size) {
            String(cString: $0)
        }
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func processArguments(_ pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var size = 0
    let firstResult = mib.withUnsafeMutableBufferPointer {
        sysctl($0.baseAddress, u_int($0.count), nil, &size, nil, 0)
    }
    guard firstResult == 0, size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    let result = mib.withUnsafeMutableBufferPointer { mibBuffer in
        bytes.withUnsafeMutableBufferPointer { byteBuffer in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), byteBuffer.baseAddress, &size, nil, 0)
        }
    }
    guard result == 0 else { return [] }
    return bytes.dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        .compactMap { String(bytes: $0, encoding: .utf8)?.lowercased() }
}

enum TranscriptMatcher {
    static func find(for process: CodexProcess, now: Date) -> URL? {
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return find(in: root.appendingPathComponent("sessions", isDirectory: true), process: process, now: now)
    }

    static func find(in sessionsRoot: URL, process: CodexProcess, now: Date) -> URL? {
        let calendar = Calendar.current
        let dates: [Date] = [process.startedAt, now]
        var seen = Set<String>()
        var candidates: [(URL, Date)] = []
        for date in dates {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard seen.insert(directory.path).inserted,
                  let entries = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
                  ) else { continue }
            for case let path as URL in entries {
                guard path.pathExtension == "jsonl" else { continue }
                guard let metadata = sessionMetadata(path),
                      normalize(metadata.cwd) == normalize(process.currentDirectory),
                      abs(metadata.startedAt.timeIntervalSince(process.startedAt)) <= ActivityTiming.sessionStartWindow else { continue }
                candidates.append((path, metadata.startedAt))
            }
        }
        return candidates.min { abs($0.1.timeIntervalSince(process.startedAt)) < abs($1.1.timeIntervalSince(process.startedAt)) }?.0
    }

    private static func sessionMetadata(_ url: URL) -> (cwd: URL, startedAt: Date)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: ActivityTiming.metadataReadLimit),
              let newline = bytes.firstIndex(of: 10),
              let envelope = try? JSONSerialization.jsonObject(with: bytes[..<newline]) as? [String: Any],
              envelope["type"] as? String == "session_meta",
              let payload = envelope["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let timestamp = payload["timestamp"] as? String,
              let date = parseSessionTimestamp(timestamp) else { return nil }
        return (URL(fileURLWithPath: cwd, isDirectory: true), date)
    }

    private static func parseSessionTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func normalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
