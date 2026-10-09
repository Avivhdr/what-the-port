import Foundation
import Testing
@testable import WhatThePort

@MainActor
struct UserCommandTests {
    @Test func suggestedNameUsesTheDirectory() {
        let script = "cd ~/my-repo && git pull && pnpm i && pnpm run serve"
        #expect(ShellLaunch.suggestedName(for: script) == "my-repo")
        #expect(ShellLaunch.suggestedName(for: "pnpm run serve") == "pnpm run serve")
        #expect(ShellLaunch.arguments(script: script) == ["-lic", script])
    }

    @Test func savedCommandSurvivesANewRunner() {
        let suite = "WhatThePortTests.commands.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = CommandRunner(defaults: defaults)
        let saved = runner.save(id: nil, name: "", script: "cd ~/my-repo && git pull && pnpm i && pnpm run serve")
        #expect(saved?.name == "my-repo")
        #expect(saved?.script == "cd ~/my-repo && git pull && pnpm i && pnpm run serve")
        let again = CommandRunner(defaults: defaults)
        #expect(again.commands == runner.commands)
    }

    @Test func aDeadJobIsDroppedOnLaunch() {
        let suite = "WhatThePortTests.jobs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = CommandJob(commandID: UUID(), pid: -1, startedAt: Date(), logPath: "/tmp/whattheport-missing.log")
        CommandStore.save(jobs: [job], to: defaults)
        let runner = CommandRunner(defaults: defaults)
        #expect(runner.jobs.isEmpty)
        #expect(CommandStore.jobs(in: defaults).isEmpty)
    }

    @Test func runRecordsTheProcessTheLauncherReturns() {
        let suite = "WhatThePortTests.run.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = CommandRunner(defaults: defaults)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        runner.launch = { _, _ in CommandLauncher.Launch(pid: 4242, startedAt: started) }
        let command = runner.save(id: nil, name: "my-repo", script: "printf 'ok\\n'")!
        runner.run(command)
        #expect(runner.jobs.first?.pid == 4242)
        #expect(runner.jobs.first?.commandID == command.id)
        #expect(runner.starting.isEmpty)
    }

    @Test func startWritesTheLogAndStopEndsTheProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wtp-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("out.log")
        let script = "printf 'ok\\n'"
        let launch = try #require(CommandLauncher.start(script: script, logURL: log, shellArguments: ["-c", script], directory: directory.path))
        defer {
            kill(launch.pid, SIGKILL)
            kill(-launch.pid, SIGKILL)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && CommandLauncher.isRunning(CommandJob(commandID: UUID(), pid: launch.pid, startedAt: launch.startedAt, logPath: log.path)) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.split(separator: "\n").contains("ok"))

        let sleepLog = directory.appendingPathComponent("sleep.log")
        let sleeping = try #require(CommandLauncher.start(script: "sleep 30", logURL: sleepLog, shellArguments: ["-c", "sleep 30"], directory: directory.path))
        let job = CommandJob(commandID: UUID(), pid: sleeping.pid, startedAt: sleeping.startedAt, logPath: sleepLog.path)
        #expect(CommandLauncher.isRunning(job))
        CommandLauncher.stop(job)
        let stopDeadline = Date().addingTimeInterval(2)
        while Date() < stopDeadline && CommandLauncher.isRunning(job) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!CommandLauncher.isRunning(job))
    }
}
