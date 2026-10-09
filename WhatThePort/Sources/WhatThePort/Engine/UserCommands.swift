import Darwin
import Foundation

/// A shell command the user saved so they can start it from the menu bar.
struct UserCommand: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var script: String
}

/// One running saved command. The pid is the session leader, so closing a
/// terminal window does not signal it.
struct CommandJob: Codable, Equatable {
    var commandID: UUID
    var pid: pid_t
    var startedAt: Date
    var logPath: String
}

enum ShellLaunch {
    static let path = "/bin/zsh"

    /// `-l` reads the login profile and `-i` reads the interactive file, so
    /// tools such as pnpm stay on PATH. The script is one argument: the shell
    /// parses `&&` and `~`.
    static func arguments(script: String) -> [String] {
        ["-lic", script]
    }

    /// `cd ~/my-repo && …` is named my-repo. Anything else keeps a short prefix.
    static func suggestedName(for script: String) -> String {
        let line = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first == "cd", tokens.count >= 2 {
            var path = tokens[1]
            if path.count >= 2, let first = path.first, let last = path.last, first == last, first == "'" || first == "\"" {
                path = String(path.dropFirst().dropLast())
            }
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty, name != "~", name != "." { return name }
        }
        if line.count <= 32 { return line }
        return String(line.prefix(32)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

enum CommandStore {
    static func commands(in defaults: UserDefaults) -> [UserCommand] {
        decode(defaults.data(forKey: Preferences.savedCommands))
    }

    static func jobs(in defaults: UserDefaults) -> [CommandJob] {
        decode(defaults.data(forKey: Preferences.runningCommands))
    }

    static func save(commands: [UserCommand], to defaults: UserDefaults) {
        defaults.set(encode(commands), forKey: Preferences.savedCommands)
    }

    static func save(jobs: [CommandJob], to defaults: UserDefaults) {
        defaults.set(encode(jobs), forKey: Preferences.runningCommands)
    }

    private static func decode<T: Decodable>(_ data: Data?) -> [T] {
        guard let data, let value = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return value
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}

enum CommandLauncher {
    struct Launch {
        let pid: pid_t
        let startedAt: Date
    }

    static func logURL(for id: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WhatThePort", isDirectory: true)
            .appendingPathComponent("command-\(id.uuidString).log")
    }

    static func isRunning(_ job: CommandJob) -> Bool {
        ProcessControl.isSameProcess(job.pid, startedAt: job.startedAt)
    }

    /// Starts `script` in a new session. Output is appended to `logURL` after a
    /// header. `shellArguments` overrides the login shell for tests.
    static func start(script: String, logURL: URL, shellArguments: [String]? = nil, directory: String? = nil) -> Launch? {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }
        let folder = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writeHeader(script, to: logURL)

        let arguments = shellArguments ?? ShellLaunch.arguments(script: script)
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let pid = spawn(shell: ShellLaunch.path, arguments: arguments, logPath: logURL.path, directory: cwd) else { return nil }
        guard let snapshot = ProcessInspector.snapshot(pid) else { return Launch(pid: pid, startedAt: Date()) }
        return Launch(pid: pid, startedAt: snapshot.startTime)
    }

    /// SIGTERM to the session, then SIGKILL to anything still alive. A reused
    /// pid is left alone.
    static func stop(_ job: CommandJob) {
        signal(job, signal: SIGTERM)
        let delay = ProcessControl.forceQuitDelay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            signal(job, signal: SIGKILL)
        }
    }

    private static func signal(_ job: CommandJob, signal: Int32) {
        guard isRunning(job) else { return }
        let processes = ProcessInspector.allProcesses()
        var victims: [pid_t] = []
        var seen = Set<pid_t>()
        func collect(_ pid: pid_t) {
            guard pid > 1, seen.insert(pid).inserted else { return }
            victims.append(pid)
            for process in processes.values where process.ppid == pid {
                collect(process.pid)
            }
        }
        collect(job.pid)
        for pid in victims where pid > 1 && pid != getpid() {
            kill(pid, signal)
        }
        // Children that stayed in the new session share this process group.
        kill(-job.pid, signal)
    }

    private static func writeHeader(_ script: String, to url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "# \(stamp)\n# \(script)\n"
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: Data(header.utf8))
    }

    /// New session (`POSIX_SPAWN_SETSID`) so the command has no controlling
    /// terminal. Closing a terminal, or quitting WhatThePort, does not send it SIGHUP.
    private static func spawn(shell: String, arguments: [String], logPath: String, directory: String) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }

        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory) == 0,
              posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) == 0 else { return nil }

        // argv[0] is the shell. The script stays one element so zsh parses `&&`.
        var argv = ([shell] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, shell, &actions, &attr, buffer.baseAddress, nil)
        }
        guard result == 0, pid > 1 else { return nil }
        return pid
    }
}

/// Saved commands and the processes they started. Owns persistence.
@MainActor
final class CommandRunner: ObservableObject {
    @Published private(set) var commands: [UserCommand] = []
    @Published private(set) var jobs: [CommandJob] = []
    @Published private(set) var starting: Set<UUID> = []
    @Published private(set) var lastError: String?

    private var cancelled: Set<UUID> = []
    private let defaults: UserDefaults
    private var timer: Timer?
    /// Test hook. Production starts the login shell.
    var launch: (String, URL) -> CommandLauncher.Launch? = { script, url in
        CommandLauncher.start(script: script, logURL: url)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = CommandStore.commands(in: defaults)
        let live = CommandStore.jobs(in: defaults).filter { CommandLauncher.isRunning($0) }
        jobs = live
        if live.count != CommandStore.jobs(in: defaults).count {
            CommandStore.save(jobs: live, to: defaults)
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let live = jobs.filter { CommandLauncher.isRunning($0) }
        guard live != jobs else { return }
        jobs = live
        CommandStore.save(jobs: jobs, to: defaults)
    }

    @discardableResult
    func save(id: UUID?, name: String, script: String) -> UserCommand? {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmedName.isEmpty ? ShellLaunch.suggestedName(for: script) : trimmedName
        var stored = commands
        let command: UserCommand
        if let id, let index = stored.firstIndex(where: { $0.id == id }) {
            command = UserCommand(id: id, name: display, script: script)
            stored[index] = command
        } else {
            command = UserCommand(id: UUID(), name: display, script: script)
            stored.append(command)
        }
        commands = stored
        CommandStore.save(commands: commands, to: defaults)
        return command
    }

    func run(_ command: UserCommand) {
        guard commands.contains(where: { $0.id == command.id }), !starting.contains(command.id) else { return }
        let previous = jobs.first { $0.commandID == command.id }
        if let previous {
            CommandLauncher.stop(previous)
            jobs.removeAll { $0.commandID == command.id }
            CommandStore.save(jobs: jobs, to: defaults)
        }
        starting.insert(command.id)
        lastError = nil
        let log = CommandLauncher.logURL(for: command.id)
        let launch = self.launch
        // Wait for the old process off the main thread. A fresh command starts now.
        guard previous != nil else {
            finish(command, started: launch(command.script, log), log: log)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(ProcessControl.forceQuitDelay + 0.4)
            while Date() < deadline, let previous, CommandLauncher.isRunning(previous) {
                usleep(100_000)
            }
            let started = launch(command.script, log)
            DispatchQueue.main.async {
                self?.finish(command, started: started, log: log)
            }
        }
    }

    func stop(_ command: UserCommand) {
        if starting.contains(command.id) {
            cancelled.insert(command.id)
            starting.remove(command.id)
        }
        guard let job = jobs.first(where: { $0.commandID == command.id }) else { return }
        CommandLauncher.stop(job)
        jobs.removeAll { $0.commandID == command.id }
        CommandStore.save(jobs: jobs, to: defaults)
    }

    func remove(_ command: UserCommand) {
        stop(command)
        starting.remove(command.id)
        commands.removeAll { $0.id == command.id }
        CommandStore.save(commands: commands, to: defaults)
        try? FileManager.default.removeItem(at: CommandLauncher.logURL(for: command.id))
    }

    func job(for id: UUID) -> CommandJob? {
        jobs.first { $0.commandID == id }
    }

    /// The saved command that started this server, when one is still running.
    func command(for server: Server) -> UserCommand? {
        for job in jobs {
            guard port(for: job, servers: [server]) == server.port else { continue }
            return commands.first { $0.id == job.commandID }
        }
        return nil
    }

    /// The listening server this command started, when one is up.
    func port(for job: CommandJob, servers: [Server]) -> Int? {
        for server in servers {
            var pid: pid_t? = server.rootPid
            for _ in 0..<12 {
                guard let current = pid, current > 1 else { break }
                if current == job.pid { return server.port }
                pid = ProcessInspector.snapshot(current)?.ppid
            }
        }
        return nil
    }

    private func finish(_ command: UserCommand, started: CommandLauncher.Launch?, log: URL) {
        starting.remove(command.id)
        let dropped = cancelled.remove(command.id) != nil || !commands.contains { $0.id == command.id }
        guard !dropped else {
            if let started {
                CommandLauncher.stop(CommandJob(commandID: command.id, pid: started.pid, startedAt: started.startedAt, logPath: log.path))
            }
            return
        }
        guard let started else {
            lastError = L10n.text("Could not start the command.")
            return
        }
        lastError = nil
        var stored = jobs.filter { $0.commandID != command.id }
        stored.append(CommandJob(commandID: command.id, pid: started.pid, startedAt: started.startedAt, logPath: log.path))
        jobs = stored
        CommandStore.save(jobs: jobs, to: defaults)
    }
}
