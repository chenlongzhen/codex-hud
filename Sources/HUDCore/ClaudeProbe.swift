import Foundation
import Darwin

/// Runs only the official CLI with fixed arguments. No credentials or raw terminal output are read/logged by HUD.
public final class ClaudeProbe: @unchecked Sendable {
    public struct Options {
        public var executable: String?
        public var configDirectory: String?
        public var snapshotDirectory: String?
        public var probeDirectory: String?
        public init(executable: String? = nil, configDirectory: String? = nil, snapshotDirectory: String? = nil, probeDirectory: String? = nil) {
            self.executable = executable; self.configDirectory = configDirectory
            self.snapshotDirectory = snapshotDirectory; self.probeDirectory = probeDirectory
        }
    }
    public struct Report {
        public var result: ClaudeProbeResult
        public var childPID: Int32?
        public var exitStatus: Int32?
        public var elapsed: Double
        public init(result: ClaudeProbeResult, childPID: Int32? = nil, exitStatus: Int32? = nil, elapsed: Double) {
            self.result = result; self.childPID = childPID; self.exitStatus = exitStatus; self.elapsed = elapsed
        }
        public var json: [String: Any] {
            func window(_ value: ClaudeProbeWindow?) -> Any {
                guard let value else { return NSNull() }
                return ["usedPercentage": value.usedPercentage, "resetsAt": value.resetsAt.map { $0 as Any } ?? NSNull()] as [String: Any]
            }
            return ["status": result.status.rawValue, "fiveHour": window(result.fiveHour), "sevenDay": window(result.sevenDay),
                    "retryAfter": result.retryAfter.map { $0 as Any } ?? NSNull(), "childPid": childPID.map { $0 as Any } ?? NSNull(),
                    "exitStatus": exitStatus.map { $0 as Any } ?? NSNull(), "elapsedSeconds": elapsed]
        }
    }
    private let condition = NSCondition()
    private var active = false
    private var cancelled = false
    private var cancellationVersion: UInt64 = 0
    public var cancellationToken: UInt64 { condition.lock(); defer { condition.unlock() }; return cancellationVersion }
    private var timeout: Double = 30
    private var grace: Double = 2
    public init() {}
    #if DEBUG
    init(timeout: Double, grace: Double) { self.timeout = timeout; self.grace = grace }
    #endif
    public func cancel() { condition.lock(); cancelled = true; cancellationVersion &+= 1; condition.unlock() }
    public func cancelAndWait() {
        condition.lock(); cancelled = true; cancellationVersion &+= 1
        let until = Date().addingTimeInterval(grace + 1)
        while active { if !condition.wait(until: until) { break } }
        condition.unlock()
    }
    private var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    private func begin(expectedVersion: UInt64? = nil) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !active, expectedVersion == nil || expectedVersion == cancellationVersion else { return false }
        active = true; cancelled = false; return true
    }
    private func end() { condition.lock(); active = false; condition.broadcast(); condition.unlock() }
    private static var uptime: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    static var identity: (home: String, user: String)? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir, let name = pw.pointee.pw_name else { return nil }
        return (String(cString: home), String(cString: name))
    }
    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let p = realpath(path, nil) else { return nil }
        defer { free(p) }; return String(cString: p)
    }
    /// Symlink entrypoints are allowed; only the verified canonical executable is spawned.
    public static func validatedExecutable(_ path: String) -> String? {
        guard let resolved = canonical(path) else { return nil }
        var info = stat()
        guard lstat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0, access(resolved, X_OK) == 0 else { return nil }
        var parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        while true {
            guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0 else { return nil }
            if parent == "/" { break }; parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        return resolved
    }
    public static func findExecutable(override: String? = nil) -> String? {
        if let override, !override.isEmpty { return validatedExecutable(override) }
        guard let home = identity?.home else { return nil }
        for path in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if let result = validatedExecutable(path) { return result }
        }
        return nil
    }
    private static func environment(executable: String, config: String?) -> [String: String]? {
        guard let identity else { return nil }
        let dir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        var path = "/usr/bin:/bin:/usr/sbin:/sbin:\(dir)"
        // Only a node shebang requires a Node interpreter. Native npm binaries do not.
        let fd = open(executable, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &bytes, bytes.count)
        guard n >= 0 else { return nil }
        let prefix = String(decoding: bytes.prefix(n), as: UTF8.self).components(separatedBy: "\n")[0]
        if prefix.hasPrefix("#!"), prefix.contains("node") {
            let candidates = [dir + "/node", identity.home + "/.local/bin/node", identity.home + "/.npm-global/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            guard let node = candidates.compactMap({ validatedExecutable($0) }).first else { return nil }
            path = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":" + path
        }
        var env = ["HOME": identity.home, "USER": identity.user, "LOGNAME": identity.user, "PATH": path,
                   "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "COLUMNS": "120", "LINES": "40", "DISABLE_AUTOUPDATER": "1"]
        if let config, !config.isEmpty {
            guard config.hasPrefix("/"), !config.utf8.contains(0) else { return nil }
            env["CLAUDE_CONFIG_DIR"] = config
        }
        return env
    }
    /// Detect is an explicit user action: login shell startup files may execute. Never used automatically.
    public func detectExecutable() -> String? {
        if let known = Self.findExecutable() { return known }
        guard begin() else { return nil }; defer { end() }
        guard let identity = Self.identity else { return nil }
        let env = ["HOME": identity.home, "USER": identity.user, "LOGNAME": identity.user, "PATH": "/usr/bin:/bin"]
        var pipes: [Int32] = [0, 0]; guard pipe(&pipes) == 0 else { return nil }
        defer { close(pipes[0]) }
        _ = fcntl(pipes[0], F_SETFL, O_NONBLOCK); _ = fcntl(pipes[0], F_SETFD, FD_CLOEXEC)
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { close(pipes[1]); return nil }; defer { close(null) }
        let pid = Self.spawn(executable: "/bin/zsh", arguments: ["-lc", "command -v claude"], environment: env,
                             directory: identity.home, input: null, output: pipes[1], error: null)
        close(pipes[1]); guard let pid else { return nil }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 2048)
        let deadline = Self.uptime + 5
        while Self.uptime < deadline && !isCancelled {
            let n = read(pipes[0], &bytes, bytes.count)
            if n > 0 { data.append(contentsOf: bytes.prefix(n)); if data.count > 8192 { break } }
            if Self.hasExited(pid) { break }
            var p = pollfd(fd: pipes[0], events: Int16(POLLIN), revents: 0); _ = poll(&p, 1, 30)
        }
        _ = terminate(pid)
        guard !isCancelled, data.count <= 8192,
              let first = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines).first else { return nil }
        return Self.validatedExecutable(first)
    }
    /// Private bootstrap mode in this same binary. POSIX spawn starts a fresh session;
    /// this tiny child attaches the PTY before exec'ing the fixed official CLI command.
    /// It loads no HUD settings, and only runs on a session-leader TTY (never a normal UI launch).
    public static func executePTYChildIfRequested(_ args: [String]) {
        guard args.contains("--claude-probe-exec") else { return }
        guard args.count == 3, args[1] == "--claude-probe-exec", getpgrp() == getpid(), getsid(0) == getpid(),
              isatty(0) == 1, let executable = validatedExecutable(args[2]),
              ioctl(0, TIOCSCTTY, 0) == 0 else { _exit(126) }
        // Foundation may add __CF_USER_TEXT_ENCODING during bootstrap. Rebuild envp from
        // the same whitelist, rather than passing the bootstrap's modified environment on.
        let inherited = ProcessInfo.processInfo.environment
        guard let env = environment(executable: executable, config: inherited["CLAUDE_CONFIG_DIR"]) else { _exit(126) }
        let argumentStrings: [String] = [executable, "--safe-mode", "--strict-mcp-config", "/usage"]
        let argv = argumentStrings.map { strdup($0) }
        let envp = env.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { _exit(126) }
        (argv + [nil]).withUnsafeBufferPointer { a in
            (envp + [nil]).withUnsafeBufferPointer { e in
                _ = execve(executable, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
            }
        }
        _exit(126)
    }
    public func run(_ options: Options = .init(), cancellationToken: UInt64? = nil) -> Report {
        let start = Self.uptime
        func report(_ status: ClaudeProbeStatus) -> Report { Report(result: .init(status: status), elapsed: Self.uptime - start) }
        guard begin(expectedVersion: cancellationToken) else {
            return report(cancellationToken != nil && cancellationToken != self.cancellationToken ? .cancelled : .busy)
        }
        defer { end() }
        guard let executable = Self.findExecutable(override: options.executable) else {
            return report(options.executable?.isEmpty == false ? .untrustedExecutable : .notFound)
        }
        guard let env = Self.environment(executable: executable, config: options.configDirectory) else { return report(.needsNode) }
        let lock: Int32
        do { guard let fd = try ClaudeSnapshotFile.acquireProbeLock(directory: options.snapshotDirectory) else { return report(.busy) }; lock = fd }
        catch { return report(.probeDirUntrusted) }
        defer { close(lock) }
        let cwd: String
        do { cwd = try ClaudeSnapshotFile.prepareProbeDirectory(override: options.probeDirectory) }
        catch ClaudeSnapshotFile.ProbeDirectoryFailure.notEmpty { return report(.probeDirNotEmpty) }
        catch { return report(.probeDirUntrusted) }
        guard !isCancelled else { return report(.cancelled) }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return report(.spawnFailed) }
        var masterOpen = true
        defer { if masterOpen { close(master) } }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0, fcntl(slave, F_SETFD, FD_CLOEXEC) == 0 else { close(slave); return report(.spawnFailed) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        guard let bootstrap = Self.canonical(URL(fileURLWithPath: CommandLine.arguments[0]).path) else { close(slave); return report(.spawnFailed) }
        let child = Self.spawn(executable: bootstrap, arguments: ["--claude-probe-exec", executable], environment: env,
                               directory: cwd, input: slave, output: slave, error: slave,
                               controllingTerminal: ttyname(slave).map { String(cString: $0) })
        close(slave)
        guard let pid = child else { return report(.spawnFailed) }
        var screen = ClaudeUsageScreen(), total = 0
        var result = ClaudeProbeResult(status: .timeout)
        var successAt: Double?, trustAt: Double?
        var bytes = [UInt8](repeating: 0, count: 8192)
        while Self.uptime - start < timeout {
            if isCancelled { result = .init(status: .cancelled); break }
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 40)
            let n = read(master, &bytes, bytes.count)
            if n > 0 {
                total += n
                if total > 1_048_576 { result = .init(status: .outputOverflow); break }
                // Do not repeatedly render/regex unbounded junk. A normal usage frame is a
                // few KiB; beyond this parse budget keep counting only, then fail closed.
                if total > 65_536 { result = .init(status: .outputOverflow); break }
                screen.feed(Array(bytes.prefix(n)))
                // Printable junk with no terminal structure needs no expensive screen parse.
                if !bytes.prefix(n).contains(10) && !bytes.prefix(n).contains(27) { continue }
                let parsed = ClaudeUsageParser.parse(screen.text, now: Int64(Date().timeIntervalSince1970))
                if parsed.status == .trustPrompt {
                    if trustAt == nil {
                        guard ClaudeUsageParser.trustPromptPathMatches(screen.screenLines, probeDirectory: cwd, home: env["HOME"]!),
                              Self.trustHasSafeDefault(screen.screenLines) else { result = .init(status: .trustPrompt); break }
                        let arrow = screen.applicationCursorKeys ? "\u{1b}OB" : "\u{1b}[B"
                        if !Self.send(arrow, to: master) || !Self.send("\r", to: master) { result = .init(status: .trustFailed); break }
                        trustAt = Self.uptime
                    }
                } else if parsed.status == .success {
                    result = parsed
                    if successAt == nil { successAt = Self.uptime }
                } else if [.loginRequired, .notSubscription, .rateLimited].contains(parsed.status) {
                    result = parsed; break
                } else if successAt == nil { result = parsed }
            }
            if let trustAt, Self.uptime - trustAt > 5, ClaudeUsageParser.isTrustPrompt(screen.text) { result = .init(status: .trustFailed); break }
            if let successAt, Self.uptime - successAt >= 0.5 { break }
            if Self.hasExited(pid) { break }
        }
        if isCancelled { result = .init(status: .cancelled) }
        else if result.status == .loading { result = .init(status: .timeout) }
        else if result.status == .trustPrompt { result = .init(status: .trustFailed) }
        // No text commands are sent into a possibly still-active usage panel. SIGTERM is a
        // supported cancellation path; killing the group also covers helper descendants.
        // On macOS a dying tty writer can wait for undrained output even after SIGKILL.
        // Hang up the master before reaping; otherwise overflow cancellation can deadlock.
        close(master); masterOpen = false
        let status = terminate(pid)
        return Report(result: result, childPID: pid, exitStatus: status, elapsed: Self.uptime - start)
    }
    private static func trustHasSafeDefault(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("❯") && $0.lowercased().contains("no") && $0.lowercased().contains("exit") }
            && lines.contains { $0.lowercased().contains("yes") && $0.lowercased().contains("trust") }
    }
    private static func send(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
    }
    private static func hasExited(_ pid: Int32) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }
    /// Keep the child unreaped while signaling its group, avoiding a reused PID/PGID.
    private func terminate(_ pid: Int32) -> Int32? {
        _ = kill(-pid, SIGTERM)
        let deadline = Self.uptime + grace
        while !Self.hasExited(pid), Self.uptime < deadline { usleep(10_000) }
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { return nil } }
        return status
    }
    private static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String,
                              input: Int32, output: Int32, error: Int32, controllingTerminal: String? = nil) -> Int32? {
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(), mask = sigset_t(); sigfillset(&defaults); sigemptyset(&mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setflags(&attr, Int16(flags)) == 0,
              posix_spawnattr_setsigdefault(&attr, &defaults) == 0, posix_spawnattr_setsigmask(&attr, &mask) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else { return nil }
        if let terminal = controllingTerminal {
            // Opening the slave *after* SETSID acquires the controlling terminal. Merely
            // duplicating the parent's already-open slave is not sufficient on every macOS.
            guard posix_spawn_file_actions_addopen(&actions, 0, terminal, O_RDWR, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, 0, 1) == 0,
                  posix_spawn_file_actions_adddup2(&actions, 0, 2) == 0 else { return nil }
        } else {
            guard posix_spawn_file_actions_adddup2(&actions, input, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, output, 1) == 0,
                  posix_spawn_file_actions_adddup2(&actions, error, 2) == 0 else { return nil }
        }
        for fd in Set([input, output, error]) where fd > 2 { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { return nil } }
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return nil }
        var pid: pid_t = 0
        let rc = (argv + [nil]).withUnsafeBufferPointer { a in
            (envp + [nil]).withUnsafeBufferPointer { e in
                posix_spawn(&pid, executable, &actions, &attr, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
            }
        }
        return rc == 0 ? pid : nil
    }
}
