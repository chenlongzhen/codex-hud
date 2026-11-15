import Foundation
import Darwin

public enum ClaudeWriteResult: String { case written, throttled, lockBusy, clockSkew, refused }

/// All business-data IO is relative to verified, no-follow directory descriptors.
/// Same-UID malicious mutation of private directories is outside the threat model.
public enum ClaudeSnapshotFile {
    private static let flags = O_NOFOLLOW | O_CLOEXEC
    private static func directoryOK(_ fd: Int32, privateOnly: Bool) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & (privateOnly ? 0o077 : 0o022) == 0
    }
    private static func walk(_ absolute: String) throws -> Int32 {
        guard absolute.hasPrefix("/"), !absolute.utf8.contains(0) else { throw ClaudeReadFailure.untrustedLocation }
        let parts = absolute.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".."), !parts.contains(".") else { throw ClaudeReadFailure.untrustedLocation }
        var fd = open("/", O_RDONLY | O_DIRECTORY | flags)
        guard fd >= 0 else { throw ClaudeReadFailure.ioError }
        for part in parts {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | flags)
            close(fd)
            guard next >= 0 else { throw errno == ENOENT ? ClaudeReadFailure.ioError : ClaudeReadFailure.untrustedLocation }
            fd = next
        }
        return fd
    }
    private static func child(_ parent: Int32, name: String, create: Bool, privateOnly: Bool) throws -> Int32 {
        var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | flags)
        if fd < 0, errno == ENOENT, create {
            if mkdirat(parent, name, 0o700) == 0 {
                // Only our just-created object is corrected. Reopen and verify after chmod;
                // existing/EEXIST objects are never silently chmodded. O_EVTONLY also requires
                // access on macOS, so fchmodat is needed when umask 0777 created mode 000.
                guard fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { throw ClaudeReadFailure.ioError }
            } else if errno != EEXIST { throw ClaudeReadFailure.ioError }
            fd = openat(parent, name, O_RDONLY | O_DIRECTORY | flags)
        }
        guard fd >= 0 else { throw errno == ENOENT ? ClaudeReadFailure.ioError : ClaudeReadFailure.untrustedLocation }
        guard directoryOK(fd, privateOnly: privateOnly) else { close(fd); throw ClaudeReadFailure.untrustedLocation }
        return fd
    }
    private static func directory(override: String?, create: Bool) throws -> Int32? {
        if let path = override {
            guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.utf8.contains(0) else { throw ClaudeReadFailure.untrustedLocation }
            let url = URL(fileURLWithPath: path)
            let parent = try walk(url.deletingLastPathComponent().path); defer { close(parent) }
            guard directoryOK(parent, privateOnly: false) else { throw ClaudeReadFailure.untrustedLocation }
            if !create {
                var info = stat()
                if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { return nil }
            }
            return try child(parent, name: url.lastPathComponent, create: create, privateOnly: true)
        }
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { throw ClaudeReadFailure.untrustedLocation }
        let root = try walk(String(cString: home)); defer { close(root) }
        guard directoryOK(root, privateOnly: false) else { throw ClaudeReadFailure.untrustedLocation }
        let library = try child(root, name: "Library", create: false, privateOnly: false); defer { close(library) }
        let support = try child(library, name: "Application Support", create: false, privateOnly: false); defer { close(support) }
        var info = stat()
        if !create, fstatat(support, "Codex HUD", &info, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { return nil }
        let app = try child(support, name: "Codex HUD", create: create, privateOnly: false); defer { close(app) }
        if !create, fstatat(app, "claude", &info, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { return nil }
        return try child(app, name: "claude", create: create, privateOnly: true)
    }
    private static func validateFile(_ fd: Int32, maxSize: Int64 = 16 * 1024) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ClaudeReadFailure.ioError }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ClaudeReadFailure.notRegularFile }
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ClaudeReadFailure.permissions }
        guard info.st_size <= maxSize else { throw ClaudeReadFailure.tooLarge }
    }
    private static func readAt(_ dir: Int32, now: Int64, recoverFutureObservation: Bool = false) -> ClaudeFileResult {
        let fd = openat(dir, "snapshot.json", O_RDONLY | O_NONBLOCK | flags)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .failed(errno == ELOOP ? .untrustedLocation : .ioError) }
        defer { close(fd) }
        do {
            try validateFile(fd)
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &bytes, min(bytes.count, 16 * 1024 + 1 - data.count))
                if count < 0 { if errno == EINTR { continue }; throw ClaudeReadFailure.ioError }
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 16 * 1024 { throw ClaudeReadFailure.tooLarge }
            }
            do { return .valid(try ClaudeSnapshot.decode(data, now: now)) }
            catch ClaudeReadFailure.clockSkew {
                // Writer only: distinguish a structurally valid future observation from
                // corrupt/reset/changedAt anomalies. Never expose this fallback to HUD reads.
                if recoverFutureObservation,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let seen = (object["bridgeSeenAt"] as? NSNumber)?.doubleValue,
                   seen.isFinite, seen > Double(now), seen >= Double(ClaudeSnapshot.minTime),
                   seen <= Double(ClaudeSnapshot.maxTime), seen.rounded(.down) == seen,
                   let future = try? ClaudeSnapshot.decode(data, now: Int64(seen)) { return .valid(future) }
                throw ClaudeReadFailure.clockSkew
            }
        } catch let error as ClaudeReadFailure { return .failed(error) }
        catch { return .failed(.malformed) }
    }
    public static func read(directory override: String? = nil, now: Int64) -> ClaudeFileResult {
        do {
            guard let fd = try directory(override: override, create: false) else { return .absent }
            defer { close(fd) }; return readAt(fd, now: now)
        } catch let error as ClaudeReadFailure { return .failed(error) }
        catch { return .failed(.ioError) }
    }
    private static func lock(_ dir: Int32) throws -> Int32? {
        var fd = openat(dir, ".lock", O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | flags, 0o600)
        if fd >= 0 {
            guard fchmod(fd, 0o600) == 0 else { close(fd); throw ClaudeReadFailure.ioError }
        } else if errno == EEXIST { fd = openat(dir, ".lock", O_RDWR | O_NONBLOCK | flags) }
        guard fd >= 0 else { throw ClaudeReadFailure.ioError }
        do { try validateFile(fd) } catch { close(fd); throw error }
        let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            guard errno == EWOULDBLOCK || errno == EINTR else { close(fd); throw ClaudeReadFailure.ioError }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        close(fd); return nil
    }
    public static func write(input: ClaudeStatuslineInput, directory override: String? = nil, now: Int64) -> ClaudeWriteResult {
        writeImpl(input: input, directory: override, now: now, beforeReplace: nil)
    }
    // Internal hook is available only to debug @testable imports, not to the CLI.
    #if DEBUG
    static func writeForTesting(input: ClaudeStatuslineInput, directory: String, now: Int64, beforeReplace: (() throws -> Void)?) -> ClaudeWriteResult {
        writeImpl(input: input, directory: directory, now: now, beforeReplace: beforeReplace)
    }
    #endif
    private static func writeImpl(input: ClaudeStatuslineInput, directory override: String?, now: Int64, beforeReplace: (() throws -> Void)?) -> ClaudeWriteResult {
        do {
            guard let dir = try directory(override: override, create: true) else { return .refused }; defer { close(dir) }
            guard let locked = try lock(dir) else { return .lockBusy }; defer { close(locked) }
            let old = readAt(dir, now: now, recoverFutureObservation: true)
            switch old {
            case .failed(.untrustedLocation), .failed(.notRegularFile), .failed(.permissions), .failed(.ioError): return .refused
            default: break
            }
            guard let merged = try ClaudeSnapshotMerge.merge(existing: old.snapshot, input: input, now: now) else { return .throttled }
            let data = try merged.encoded(now: now)
            let name = "snapshot.json.tmp.\(getpid()).\(String(format: "%08x", arc4random()))"
            let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | flags, 0o600)
            guard fd >= 0 else { return .refused }
            var closed = false
            defer { if !closed { close(fd) }; _ = unlinkat(dir, name, 0) }
            guard fchmod(fd, 0o600) == 0 else { return .refused }
            try validateFile(fd)
            let success = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { return false }; offset += count
                }
                return true
            }
            guard success, fsync(fd) == 0 else { return .refused }
            close(fd); closed = true
            try beforeReplace?()
            guard renameat(dir, name, dir, "snapshot.json") == 0 else { return .refused }
            cleanup(dir, now: now)
            return .written
        } catch ClaudeReadFailure.clockSkew { return .clockSkew }
        catch { return .refused }
    }
    private static func cleanup(_ dir: Int32, now: Int64) {
        let copied = dup(dir)
        guard copied >= 0 else { return }
        guard let listing = fdopendir(copied) else { close(copied); return }; defer { closedir(listing) }
        var scanned = 0, deleted = 0
        while let entry = readdir(listing), scanned < 512, deleted < 16 {
            scanned += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            guard name.range(of: "\\Asnapshot\\.json\\.tmp\\.[0-9]+\\.[0-9a-f]{8}\\z", options: .regularExpression) != nil, !name.contains("/") else { continue }
            var info = stat()
            if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mtimespec.tv_sec < now - 60 {
                if unlinkat(dir, name, 0) == 0 { deleted += 1 }
            }
        }
    }
    /// Uses the same stable lock as writers; never deletes .lock.
    public static func clear(directory override: String? = nil) -> Bool {
        do {
            guard let dir = try directory(override: override, create: false) else { return true }; defer { close(dir) }
            guard let locked = try lock(dir) else { return false }; defer { close(locked) }
            let fd = openat(dir, "snapshot.json", O_RDONLY | O_NONBLOCK | flags)
            if fd < 0 { return errno == ENOENT }
            defer { close(fd) }; try validateFile(fd)
            return unlinkat(dir, "snapshot.json", 0) == 0
        } catch { return false }
    }
}
public actor ClaudeSnapshotReader {
    public init() {}
    public func read(directory: String? = nil, now: Int64) -> ClaudeFileResult { ClaudeSnapshotFile.read(directory: directory, now: now) }
    public func clear(directory: String? = nil) -> Bool { ClaudeSnapshotFile.clear(directory: directory) }
}
