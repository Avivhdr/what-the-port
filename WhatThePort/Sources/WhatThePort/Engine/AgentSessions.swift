import Foundation

enum AgentKind: String, CaseIterable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case grok = "Grok"

    var resumeCommand: String {
        switch self {
        case .claudeCode: return "claude --resume"
        case .codex: return "codex resume"
        case .grok: return "grok --resume"
        }
    }
}

struct AgentSession: Equatable {
    let kind: AgentKind
    let id: String
    let title: String?
    let transcript: URL?
    let startedAt: Date?
    /// The directory the agent was started in, used to resume it.
    let directory: String?

    var shortID: String { String(id.prefix(8)) }
}

/// Links a server to the coding-agent session that started it.
///
/// A non-empty session id claims the process. The ids are checked in
/// `environmentClaims` order. When that agent is turned off, the process
/// stays unlinked. With no session id, Codex and Grok match by working
/// directory. The newer session in a directory wins.
final class AgentSessionResolver {
    private struct DirectoryEntry {
        let session: AgentSession
        let modified: Date
    }

    private let home: URL
    private var claudeCache: [String: (session: AgentSession, checkedAt: Date)] = [:]
    private var grokCache: [String: (session: AgentSession, checkedAt: Date)] = [:]
    private var directoryEntries: [AgentKind: [String: DirectoryEntry]] = [:]
    private var directoryRefreshedAt: [AgentKind: Date] = [:]

    /// The first non-empty id claims the process. Order is the precedence.
    private static let environmentClaims: [(kind: AgentKind, key: String)] = [
        (.claudeCode, "CLAUDE_CODE_SESSION_ID"),
        (.grok, "GROK_SESSION_ID"),
    ]

    /// Merged from first to last. A later kind wins equal modification dates.
    private static let directoryMatchOrder: [AgentKind] = [.codex, .grok]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func resolve(environment: [String: String], cwd: String?, enabled: Set<AgentKind> = Set(AgentKind.allCases)) -> AgentSession? {
        for claim in Self.environmentClaims {
            guard let id = environment[claim.key], !id.isEmpty else { continue }
            guard enabled.contains(claim.kind) else { return nil }
            return session(kind: claim.kind, id: id)
        }
        guard let cwd, !enabled.isDisjoint(with: Self.directoryMatchOrder) else { return nil }
        refreshDirectoryIndexes(enabled: enabled)
        let index = mergedDirectoryIndex(enabled: enabled)
        // Walk up from the server's directory, but never match a session that was
        // started in the home folder or above; that would claim every server.
        var directory = Self.directoryKey(cwd)
        while directory.count > home.path.count {
            if let entry = index[directory] { return entry.session }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func session(kind: AgentKind, id: String) -> AgentSession {
        switch kind {
        case .claudeCode: return claudeSession(id: id)
        case .grok: return grokSession(id: id)
        case .codex:
            preconditionFailure("Codex sessions are matched by directory, not by an environment id")
        }
    }

    private func refreshDirectoryIndexes(enabled: Set<AgentKind>) {
        if enabled.contains(.codex) { refreshCodexIndexIfNeeded() }
        if enabled.contains(.grok) { refreshGrokIndexIfNeeded() }
    }

    /// One path map for this scan. Each agent's own index stays intact, so turning
    /// an agent off takes effect before the 60-second refresh interval.
    private func mergedDirectoryIndex(enabled: Set<AgentKind>) -> [String: DirectoryEntry] {
        var index: [String: DirectoryEntry] = [:]
        for kind in Self.directoryMatchOrder where enabled.contains(kind) {
            for (path, entry) in directoryEntries[kind] ?? [:] {
                if let existing = index[path], existing.modified > entry.modified { continue }
                index[path] = entry
            }
        }
        return index
    }

    // MARK: - Claude Code

    private func claudeSession(id: String) -> AgentSession {
        if let cached = claudeCache[id], Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.session
        }
        let transcript = findClaudeTranscript(id: id)
        var title: String?
        var directory: String?
        if let transcript {
            // Titles are appended as the session goes, so the newest is near the end.
            let head = Self.readHead(of: transcript, bytes: 256 * 1024)
            title = Self.lastTitle(in: Self.readTail(of: transcript, bytes: 512 * 1024))
                ?? Self.lastTitle(in: head)
                ?? Self.firstPrompt(in: head)
            directory = Self.firstValue(of: "cwd", in: head)
        }
        let created = transcript.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        let session = AgentSession(kind: .claudeCode, id: id, title: title, transcript: transcript, startedAt: created, directory: directory)
        claudeCache[id] = (session, Date())
        return session
    }

    private func findClaudeTranscript(id: String) -> URL? {
        let projects = home.appendingPathComponent(".claude/projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func lastTitle(in text: String) -> String? {
        var title: String?
        for line in text.split(separator: "\n") where line.contains("\"type\":\"custom-title\"") || line.contains("\"type\":\"ai-title\"") {
            guard let object = json(line) else { continue }
            if let custom = object["customTitle"] as? String, !custom.isEmpty { return custom }
            if let ai = object["aiTitle"] as? String, !ai.isEmpty { title = ai }
        }
        return title
    }

    private static func firstPrompt(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"type\":\"user\"") {
            guard let object = json(line),
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? String else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("<") { continue }
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            return String(firstLine.prefix(60))
        }
        return nil
    }

    private static func firstValue(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"\(key)\"") {
            if let value = json(line)?[key] as? String { return value }
        }
        return nil
    }

    // MARK: - Codex

    private func refreshCodexIndexIfNeeded() {
        guard Date().timeIntervalSince(directoryRefreshedAt[.codex] ?? .distantPast) > 60 else { return }
        directoryRefreshedAt[.codex] = Date()

        let codex = home.appendingPathComponent(".codex")
        var titles: [String: String] = [:]
        let indexText = Self.readTail(of: codex.appendingPathComponent("session_index.jsonl"), bytes: 1024 * 1024)
        for line in indexText.split(separator: "\n") {
            if let object = Self.json(line), let id = object["id"] as? String, let name = object["thread_name"] as? String {
                titles[id] = name
            }
        }

        var index: [String: DirectoryEntry] = [:]
        let sessionsRoot = codex.appendingPathComponent("sessions")
        let cutoff = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            directoryEntries[.codex] = [:]
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > cutoff else { continue }
            let head = Self.readHead(of: url, bytes: 64 * 1024)
            guard let first = head.split(separator: "\n").first,
                  let object = Self.json(first),
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else { continue }
            let key = Self.directoryKey(cwd)
            if let existing = index[key], existing.modified > modified { continue }
            let started = (payload["timestamp"] as? String).flatMap { Self.parseISO($0) }
            let session = AgentSession(kind: .codex, id: id, title: titles[id], transcript: url, startedAt: started, directory: key)
            index[key] = DirectoryEntry(session: session, modified: modified)
        }
        directoryEntries[.codex] = index
    }

    // MARK: - Grok

    private func grokSession(id: String) -> AgentSession {
        if let cached = grokCache[id], Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.session
        }
        let summary = findGrokSummary(id: id)
        let session = Self.makeGrokSession(id: id, summary: summary)
        grokCache[id] = (session, Date())
        return session
    }

    /// `~/.grok/sessions/<percent-encoded cwd>/<session id>/summary.json`.
    private func findGrokSummary(id: String) -> URL? {
        let root = home.appendingPathComponent(".grok/sessions")
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let candidate = folder.appendingPathComponent(id).appendingPathComponent("summary.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func refreshGrokIndexIfNeeded() {
        guard Date().timeIntervalSince(directoryRefreshedAt[.grok] ?? .distantPast) > 60 else { return }
        directoryRefreshedAt[.grok] = Date()
        let root = home.appendingPathComponent(".grok/sessions")
        let cutoff = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        var index: [String: DirectoryEntry] = [:]
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            directoryEntries[.grok] = [:]
            return
        }
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in sessions {
                guard (try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let summary = sessionDir.appendingPathComponent("summary.json")
                guard let modified = try? summary.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > cutoff else { continue }
                let session = Self.makeGrokSession(id: sessionDir.lastPathComponent, summary: summary)
                // Skip a session started in the home folder. It would claim every server.
                guard let key = session.directory, key.count > home.path.count else { continue }
                if let existing = index[key], existing.modified > modified { continue }
                index[key] = DirectoryEntry(session: session, modified: modified)
            }
        }
        directoryEntries[.grok] = index
    }

    /// Reads `summary.json`. Returns a session with no title when the file is missing,
    /// so a live `GROK_SESSION_ID` can still be resumed.
    private static func makeGrokSession(id: String, summary: URL?) -> AgentSession {
        guard let summary,
              let data = try? Data(contentsOf: summary),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AgentSession(kind: .grok, id: id, title: nil, transcript: nil, startedAt: nil, directory: nil)
        }
        let info = object["info"] as? [String: Any]
        let parsedID = (info?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let directory = (info?["cwd"] as? String).flatMap { value in
            let key = directoryKey(value)
            return key.isEmpty ? nil : key
        }
        let title = shortTitle(object["generated_title"] as? String) ?? shortTitle(object["session_summary"] as? String)
        let started = (object["created_at"] as? String).flatMap { parseISO($0) }
        let transcript = summary.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl")
        let transcriptURL = FileManager.default.fileExists(atPath: transcript.path) ? transcript : nil
        return AgentSession(kind: .grok, id: parsedID, title: title, transcript: transcriptURL, startedAt: started, directory: directory)
    }

    private static func shortTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return String(line.prefix(60))
    }

    private static func directoryKey(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - File helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Grok writes microseconds (`2026-10-03T08:47:56.326370Z`). Keep three digits.
    /// A longer fraction is not a reliable input for `ISO8601DateFormatter`.
    private static func parseISO(_ value: String) -> Date? {
        isoFormatter.date(from: normalizedFractionalSeconds(value))
    }

    private static func normalizedFractionalSeconds(_ value: String) -> String {
        guard let dot = value.firstIndex(of: ".") else { return value }
        let rest = value[value.index(after: dot)...]
        guard let zone = rest.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return value }
        let fraction = rest[..<zone]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return value }
        let millis = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(value[..<dot]) + "." + millis + String(rest[zone...])
    }

    private static func json<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func readHead(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func readTail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // Drop the partial first line when we started mid-file.
        if offset > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}
