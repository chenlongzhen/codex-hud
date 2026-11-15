import Foundation
import Darwin
import HUDCore

/// Runs before NSApplication / HUDStore. No child process, settings, networking or credentials.
enum ClaudeBridge {
    static func run(arguments: [String]) -> Never {
        let start = DispatchTime.now().uptimeNanoseconds
        signal(SIGPIPE, SIG_IGN)
        // Lifecycle lasts until process exit. _exit skips buffered IO/destructors on timeout.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        watchdog.schedule(deadline: .now() + .seconds(2))
        watchdog.setEventHandler { _exit(0) }; watchdog.resume()
        defer { watchdog.cancel() }
        var silent = false, directory: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--claude-statusline-bridge": break
            case "--silent": silent = true
            case "--claude-snapshot-dir":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/"), directory == nil else { _exit(0) }
                directory = arguments[index]
            default: _exit(0)
            }
            index += 1
        }
        guard let data = readInput(deadline: start + 1_500_000_000) else { _exit(0) }
        let seconds = Date().timeIntervalSince1970
        guard seconds.isFinite, seconds >= Double(ClaudeSnapshot.minTime), seconds <= Double(ClaudeSnapshot.maxTime) else { _exit(0) }
        let now = Int64(seconds)
        guard let input = ClaudeStatuslineInput.parse(data, now: now) else { _exit(0) }
        // stdout is based on this input even if persistence fails or is lock-busy.
        _ = ClaudeSnapshotFile.write(input: input, directory: directory, now: now)
        if !silent {
            let output = Array(input.stdout.utf8)
            output.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break } // EPIPE / closed stdout are handled errors, exit 0.
                    offset += count
                }
            }
        }
        _exit(0)
    }
    private static func readInput(deadline: UInt64) -> Data? {
        let oldFlags = fcntl(STDIN_FILENO, F_GETFL)
        guard oldFlags >= 0, fcntl(STDIN_FILENO, F_SETFL, oldFlags | O_NONBLOCK) == 0 else { return nil }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let polled = poll(&descriptor, 1, Int32(min(100, max(1, (deadline - now) / 1_000_000))))
            if polled < 0 { if errno == EINTR { continue }; return nil }
            if polled == 0 { continue }
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            guard data.count + count <= 256 * 1024 else { return nil }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
