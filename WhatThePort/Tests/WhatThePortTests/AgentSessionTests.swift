import Foundation
import Testing
@testable import WhatThePort

struct AgentSessionTests {
    private let fileManager = FileManager.default

    @Test func testGrokResumeCommand() {
        #expect(AgentKind.grok.resumeCommand == "grok --resume")
        #expect(AgentKind.grok.rawValue == "Grok")
    }

    @Test func testSessionIDMatchesTheGrokSummary() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let cwd = root.path + "/work/app"
        let summary = try writeGrok(home: root, folder: "app", id: "01a100f2-d37c-7702-83e3-5a2bbf4614a1", cwd: cwd,
                                    title: "Add port colors", summary: "A longer summary that should not win",
                                    created: "2026-10-03T08:47:56.326370Z")
        try "history".write(to: summary.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
        let resolver = AgentSessionResolver(home: root)
        let session = resolver.resolve(environment: ["GROK_SESSION_ID": "01a100f2-d37c-7702-83e3-5a2bbf4614a1"], cwd: "/elsewhere")
        #expect(session?.kind == .grok)
        #expect(session?.title == "Add port colors")
        #expect(session?.directory == cwd)
        #expect(session?.transcript?.lastPathComponent == "chat_history.jsonl")
        let started = try #require(session?.startedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: started)
        #expect(parts.year == 2026)
        #expect(parts.month == 10)
        #expect(parts.day == 3)
        #expect(parts.hour == 8)
        #expect(parts.minute == 47)
        #expect(parts.second == 56)
        let fraction = started.timeIntervalSince1970 - floor(started.timeIntervalSince1970)
        #expect(Int((fraction * 1000).rounded()) == 326)
    }

    @Test func testFolderMatchUsesTheNewestSessionAndSkipsHome() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let cwd = root.path + "/work/app"
        let older = try writeGrok(home: root, folder: "old", id: "old-session", cwd: cwd, title: "Old", summary: nil,
                                  created: "2026-10-01T00:00:00.000Z")
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: older.path)
        _ = try writeGrok(home: root, folder: "new", id: "new-session", cwd: cwd, title: "New", summary: nil,
                          created: "2026-10-02T00:00:00.000Z")
        _ = try writeGrok(home: root, folder: "home", id: "home-session", cwd: root.path, title: "Home", summary: nil,
                          created: "2026-10-03T00:00:00.000Z")
        let stale = try writeGrok(home: root, folder: "stale", id: "stale-session", cwd: root.path + "/other", title: "Stale", summary: nil,
                                  created: "2026-09-01T00:00:00.000Z")
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 24 * 60 * 60)], ofItemAtPath: stale.path)

        let resolver = AgentSessionResolver(home: root)
        let matched = resolver.resolve(environment: [:], cwd: cwd + "/web", enabled: [.grok])
        #expect(matched?.id == "new-session")
        #expect(matched?.title == "New")
        #expect(resolver.resolve(environment: [:], cwd: root.path + "/unrelated", enabled: [.grok]) == nil)
        // The id is still valid after the file is older than the folder index.
        let byID = resolver.resolve(environment: ["GROK_SESSION_ID": "stale-session"], cwd: nil, enabled: [.grok])
        #expect(byID?.title == "Stale")
        #expect(byID?.directory == root.path + "/other")
    }

    @Test func testGrokEnvironmentBeatsCodexAndCanBeTurnedOff() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let cwd = root.path + "/work/app"
        _ = try writeGrok(home: root, folder: "grok", id: "grok-session", cwd: cwd, title: "Grok work", summary: nil,
                          created: "2026-10-01T00:00:00.000Z")
        let codex = root.appendingPathComponent(".codex/sessions/rollout.jsonl")
        try fileManager.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"payload":{"id":"codex-session","cwd":"\#(cwd)","timestamp":"2026-10-03T00:00:00.000Z"}}"#
        try (line + "\n").write(to: codex, atomically: true, encoding: .utf8)

        let resolver = AgentSessionResolver(home: root)
        let fromEnv = resolver.resolve(environment: ["GROK_SESSION_ID": "grok-session"], cwd: cwd)
        #expect(fromEnv?.kind == .grok)
        #expect(fromEnv?.id == "grok-session")
        #expect(resolver.resolve(environment: ["GROK_SESSION_ID": "grok-session"], cwd: cwd, enabled: [.claudeCode, .codex]) == nil)
        #expect(resolver.resolve(environment: ["CLAUDE_CODE_SESSION_ID": "claude-1", "GROK_SESSION_ID": "grok-session"], cwd: cwd)?.kind == .claudeCode)

        let grokFile = root.appendingPathComponent(".grok/sessions/grok/grok-session/summary.json")
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 60)], ofItemAtPath: grokFile.path)
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: codex.path)
        let fresh = AgentSessionResolver(home: root)
        #expect(fresh.resolve(environment: [:], cwd: cwd)?.kind == .codex)
    }

    @Test func testDisabledSessionIDDoesNotFallThrough() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let cwd = root.path + "/work/app"
        _ = try writeGrok(home: root, folder: "grok", id: "grok-session", cwd: cwd, title: "Grok work", summary: nil,
                          created: "2026-10-01T00:00:00.000Z")
        let codex = root.appendingPathComponent(".codex/sessions/rollout.jsonl")
        try fileManager.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"payload":{"id":"codex-session","cwd":"\#(cwd)","timestamp":"2026-10-03T00:00:00.000Z"}}"#
        try (line + "\n").write(to: codex, atomically: true, encoding: .utf8)

        let resolver = AgentSessionResolver(home: root)
        let both = [
            "CLAUDE_CODE_SESSION_ID": "claude-1",
            "GROK_SESSION_ID": "grok-session",
        ]
        #expect(resolver.resolve(environment: both, cwd: cwd, enabled: [.codex, .grok]) == nil)
        #expect(resolver.resolve(environment: ["CLAUDE_CODE_SESSION_ID": "claude-1"], cwd: cwd, enabled: [.codex, .grok]) == nil)
        #expect(resolver.resolve(environment: both, cwd: cwd)?.kind == .claudeCode)
    }

    @Test func testSummaryFallsBackToTheFirstLine() throws {
        let root = try makeHome()
        defer { try? fileManager.removeItem(at: root) }
        let cwd = root.path + "/work/app"
        _ = try writeGrok(home: root, folder: "app", id: "no-title", cwd: cwd + "/", title: "  ",
                          summary: "First line of the summary\nsecond line", created: "not-a-date")
        let session = AgentSessionResolver(home: root).resolve(environment: ["GROK_SESSION_ID": "no-title"], cwd: cwd)
        #expect(session?.title == "First line of the summary")
        #expect(session?.directory == cwd)
        #expect(session?.startedAt == nil)
    }

    private func makeHome() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("wtp-grok-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeGrok(home: URL, folder: String, id: String, cwd: String, title: String, summary: String?, created: String) throws -> URL {
        let directory = home.appendingPathComponent(".grok/sessions/\(folder)/\(id)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "generated_title": title,
            "created_at": created,
        ]
        if let summary { object["session_summary"] = summary }
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = directory.appendingPathComponent("summary.json")
        try data.write(to: url)
        return url
    }
}
