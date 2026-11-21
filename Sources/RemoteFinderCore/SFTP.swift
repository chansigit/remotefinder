import Foundation
import Darwin
import CryptoKit

public struct RemoteError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct ConnectionProfile: Codable, Equatable {
    public var host: String
    public var user: String
    public var port: String
    public var path: String
    public init(host: String, user: String = "", port: String = "", path: String = ".") {
        self.host = host; self.user = user; self.port = port; self.path = path
    }
    public var label: String { user.isEmpty ? host : "\(user)@\(host)" }
    public func sameServer(as other: ConnectionProfile) -> Bool {
        host == other.host && user == other.user && port == other.port
    }
    public func arguments(interactive: Bool = true) throws -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              !user.hasPrefix("-"), !user.contains("\0"), !user.contains("\n"),
              !path.contains("\0") else { throw RemoteError("请输入有效的主机名或 SSH 配置别名；用户名请填在单独的输入框。") }
        var args = ["-T", "-o", "BatchMode=no", "-o", interactive ? "StrictHostKeyChecking=ask" : "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=6",
                    "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"]
        if !interactive { args += ["-o", "NumberOfPasswordPrompts=1"] }
        if !user.isEmpty { args += ["-l", user] }
        if !port.isEmpty {
            guard let value = Int(port), (1...65535).contains(value) else { throw RemoteError("端口必须为 1–65535。") }
            args += ["-p", String(value)]
        }
        return args + ["-s", host, "sftp"]
    }
}

struct Packet {
    var data = Data()
    var position = 0
    init(_ data: Data = Data()) { self.data = data }
    mutating func putByte(_ value: UInt8) { data.append(value) }
    mutating func put32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    mutating func put64(_ value: UInt64) { put32(UInt32(value >> 32)); put32(UInt32(truncatingIfNeeded: value)) }
    mutating func putData(_ value: Data) { put32(UInt32(value.count)); data.append(value) }
    mutating func putString(_ value: String) { putData(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - position else { throw RemoteError("SFTP 数据包不完整。") }
        defer { position += count }
        return data.subdata(in: position..<(position + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { let high = try uint32(); return (UInt64(high) << 32) | UInt64(try uint32()) }
    mutating func bytes() throws -> Data { let count = try uint32(); return try take(Int(count)) }
    mutating func string() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8) else { throw RemoteError("文件名不是有效 UTF-8，无法安全显示。") }
        return text
    }
}

public struct FileAttributes {
    public var size: UInt64?
    public var permissions: UInt32?
    public var modified: Date?
    public var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    public var isLink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
    public var isRegular: Bool { permissions.map { $0 & 0o170000 == 0o100000 } ?? false }
    init(_ packet: inout Packet) throws {
        let flags = try packet.uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw RemoteError("不支持的 SFTP 文件属性。") }
        if flags & 1 != 0 { size = try packet.uint64() }
        if flags & 2 != 0 { _ = try packet.uint32(); _ = try packet.uint32() }
        if flags & 4 != 0 { permissions = try packet.uint32() }
        if flags & 8 != 0 { _ = try packet.uint32(); modified = Date(timeIntervalSince1970: TimeInterval(try packet.uint32())) }
        if flags & 0x80000000 != 0 {
            let count = try packet.uint32()
            guard count <= 65536 else { throw RemoteError("SFTP 扩展属性数量异常。") }
            for _ in 0..<count { _ = try packet.bytes(); _ = try packet.bytes() }
        }
    }
}

public struct RemoteEntry {
    public let name: String
    public let attributes: FileAttributes
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

// One worker owns protocol state. cancel() is the only cross-thread operation.
public final class SFTPClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var diagnostics = Data()
    private var sequence: UInt32 = 0
    private var timeout: TimeInterval = 180
    private var responseTimeout: TimeInterval = 90
    private var supportsAtomicReplace = false
    private var started = false
    private(set) var usedSavedPassword = false

    public init(profile: ConnectionProfile, askpass: String, interactive: Bool = true) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try profile.arguments(interactive: interactive)
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["REMOTEFINDER_PASSWORD_SERVICE"] = SSHPasswordStore(profile: profile).service
        env["REMOTEFINDER_CONNECTION_LABEL"] = profile.label
        env["REMOTEFINDER_AUTH_INTERACTIVE"] = interactive ? "1" : "0"
        // Keep password prompts predictable without changing the remote session locale.
        env["LC_MESSAGES"] = "C"
        if !interactive { timeout = 30 }
        env["DISPLAY"] = "RemoteFinder"
        process.environment = env
    }

    // Used by integration tests with the real local OpenSSH SFTP server.
    init(serverExecutable: String, arguments: [String] = [], timeout: TimeInterval = 30) {
        self.timeout = timeout; self.responseTimeout = timeout
        process.executableURL = URL(fileURLWithPath: serverExecutable)
        process.arguments = arguments
    }

    public func start() throws {
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self = self else { return }
            self.lock.lock()
            self.diagnostics.append(chunk)
            if self.diagnostics.count > 16384 { self.diagnostics = Data(self.diagnostics.suffix(16384)) }
            self.lock.unlock()
        }
        try checkCancellation()
        var authenticationState: URL?
        if process.environment?["REMOTEFINDER_PASSWORD_SERVICE"] != nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFinder-auth-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            authenticationState = directory
            var environment = process.environment ?? [:]
            environment["REMOTEFINDER_AUTH_STATE"] = directory.path
            process.environment = environment
        }
        defer {
            if let directory = authenticationState {
                usedSavedPassword = FileManager.default.fileExists(atPath: directory.appendingPathComponent("used-saved-password").path)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do { try process.run() } catch { cancel(); throw error }
        lock.lock(); started = true; let stopped = cancelled; lock.unlock()
        if stopped { cancel(); throw RemoteError("已取消。") }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        do {
            var hello = Packet(); hello.putByte(1); hello.put32(3)
            try send(hello.data)
            var reply = try receive()
            guard try reply.byte() == 2, try reply.uint32() == 3 else { throw RemoteError("服务器未提供 SFTP v3。") }
            while reply.position < reply.data.count {
                let name = try reply.string(); let version = try reply.string()
                if name == "posix-rename@openssh.com" && version == "1" { supportsAtomicReplace = true }
            }
            timeout = responseTimeout
        } catch { cancel(); throw error }
    }

    public func cancel() {
        lock.lock(); cancelled = true; let running = started; lock.unlock()
        if running && process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    public var isUsable: Bool {
        lock.lock(); let usable = started && !cancelled; lock.unlock()
        return usable && process.isRunning
    }

    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw RemoteError("已取消。") }
    }

    deinit {
        cancel()
        errors.fileHandleForReading.readabilityHandler = nil
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        errors.fileHandleForReading.closeFile()
    }

    public func diagnosticMessage(_ error: Error) -> String {
        lock.lock(); let detail = String(decoding: diagnostics, as: UTF8.self); lock.unlock()
        return detail.isEmpty ? error.localizedDescription : error.localizedDescription + "\n\n" + detail
    }

    private func wait(_ fd: Int32, _ events: Int16, until deadline: TimeInterval) throws {
        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { cancel(); throw RemoteError("服务器响应超时，请重新连接。") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno != EINTR { cancel(); throw RemoteError("SSH 管道读取失败。") }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { cancel(); throw RemoteError("SSH 连接已关闭。") }
            }
        }
    }

    private func send(_ data: Data) throws {
        var frame = Packet(); frame.put32(UInt32(data.count)); frame.data.append(data)
        let fd = input.fileHandleForWriting.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try frame.data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { cancel(); throw RemoteError("SSH 连接写入失败。") }
            }
        }
    }

    private func read(_ count: Int, until deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        let fd = output.fileHandleForReading.fileDescriptor
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(fd, Int16(POLLIN), until: deadline)
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received > 0 { offset += received }
                else if received == 0 { cancel(); throw RemoteError("SSH 连接已关闭。") }
                else if errno != EAGAIN && errno != EINTR { cancel(); throw RemoteError("SSH 连接读取失败。") }
            }
        }
        return data
    }

    private func receive() throws -> Packet {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var header = Packet(try read(4, until: deadline))
        let length = try header.uint32()
        guard length >= 1 && length <= 4 * 1024 * 1024 else { cancel(); throw RemoteError("SFTP 数据包长度异常。") }
        return Packet(try read(Int(length), until: deadline))
    }

    private func sendRequest(_ type: UInt8, _ body: Packet) throws -> UInt32 {
        sequence &+= 1
        var packet = Packet(); packet.putByte(type); packet.put32(sequence); packet.data.append(body.data)
        try send(packet.data)
        return sequence
    }

    private func response() throws -> (UInt8, UInt32, Packet) {
        do {
            var reply = try receive()
            let type = try reply.byte(); let id = try reply.uint32()
            return (type, id, reply)
        } catch { cancel(); throw error }
    }

    private func request(_ type: UInt8, _ body: Packet) throws -> (UInt8, Packet) {
        let id = try sendRequest(type, body)
        let (replyType, replyID, reply) = try response()
        guard replyID == id else { cancel(); throw RemoteError("SFTP 响应顺序异常，请重新连接。") }
        return (replyType, reply)
    }

    private func expect(_ expected: UInt8, _ result: (UInt8, Packet)) throws -> Packet {
        if result.0 == expected { return result.1 }
        if result.0 == 101 {
            var status = result.1
            let code: UInt32; let message: String
            do { code = try status.uint32(); message = try status.string() }
            catch { cancel(); throw error }
            throw RemoteError("SFTP \(code)：\(message)")
        }
        cancel(); throw RemoteError("服务器返回了不符合预期的 SFTP 响应。")
    }

    private func stringBody(_ string: String) throws -> Packet {
        guard !string.contains("\0"), string.utf8.count <= 65536 else { throw RemoteError("远程路径无效或过长。") }
        var body = Packet(); body.putString(string); return body
    }

    public func realpath(_ path: String) throws -> String {
        var reply = try expect(104, request(16, stringBody(path)))
        guard try reply.uint32() == 1 else { throw RemoteError("服务器返回了无效的路径。") }
        let resolved = try reply.string()
        guard resolved.hasPrefix("/"), !resolved.contains("\0"), resolved.utf8.count <= 65536 else {
            cancel(); throw RemoteError("服务器返回了无效的绝对路径。")
        }
        return resolved
    }

    public func stat(_ path: String) throws -> FileAttributes {
        var reply = try expect(105, request(17, stringBody(path)))
        return try FileAttributes(&reply)
    }

    public func rename(in directory: String, from oldName: String, to newName: String) throws {
        guard RemoteEntry.isSafeName(oldName), RemoteEntry.isSafeName(newName) else {
            throw RemoteError("名称不能为空、不能是 . 或 ..，也不能包含 / 或空字符。")
        }
        if oldName == newName { return }
        let prefix = directory == "/" ? "/" : directory + "/"
        var body = try stringBody(prefix + oldName)
        body.data.append(try stringBody(prefix + newName).data)
        // Standard v3 RENAME rejects existing destinations; POSIX rename would overwrite.
        var reply = try expect(101, request(18, body))
        let code = try reply.uint32()
        guard code == 0 else {
            let message = try reply.string()
            throw RemoteError("重命名失败（SFTP \(code)）：\(message)\n请检查是否有同名项目或目录写入权限。")
        }
    }

    private func close(_ handle: Data) throws {
        var body = Packet(); body.putData(handle)
        var reply = try expect(101, request(4, body))
        guard try reply.uint32() == 0 else { throw RemoteError("关闭远程文件失败。") }
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        var reply = try expect(102, request(11, stringBody(path)))
        let handle = try reply.bytes()
        defer { try? close(handle) }
        var entries: [RemoteEntry] = []
        var bytes = 0
        var received = 0
        while true {
            var body = Packet(); body.putData(handle)
            let (type, packet) = try request(12, body)
            var batch = packet
            if type == 101 {
                if try batch.uint32() == 1 { break }
                _ = try expect(104, (type, packet))
            }
            batch = try expect(104, (type, packet))
            let count = try batch.uint32()
            guard count > 0 && count <= 100000 else { throw RemoteError("SFTP 目录响应数量异常。") }
            received += Int(count); bytes += max(packet.data.count, Int(count) * 128)
            guard received <= 200002, bytes <= 64 * 1024 * 1024 else {
                throw RemoteError("目录超过安全加载上限（20 万项或约 64 MB），请直接打开更具体的子目录。")
            }
            for _ in 0..<count {
                try checkCancellation()
                let name = try batch.string(); _ = try batch.bytes()
                let attributes = try FileAttributes(&batch)
                if name == "." || name == ".." { continue }
                guard RemoteEntry.isSafeName(name) else { throw RemoteError("服务器返回了不安全的文件名。") }
                entries.append(RemoteEntry(name: name, attributes: attributes))
            }
        }
        return entries
    }

    private func statusOK(_ result: (UInt8, Packet)) throws {
        var reply = try expect(101, result)
        let code = try reply.uint32()
        guard code == 0 else { throw RemoteError("SFTP \(code)：\(try reply.string())") }
    }

    func attributesIfPresent(_ path: String) throws -> FileAttributes? {
        let result = try request(7, stringBody(path)) // LSTAT: never overwrite a symlink.
        if result.0 == 101 {
            var packet = result.1
            if try packet.uint32() == 2 { return nil }
        }
        var packet = try expect(105, result)
        return try FileAttributes(&packet)
    }

    func fingerprint(_ path: String, progress: (UInt64, UInt64) -> Void = { _, _ in }) throws -> String? {
        guard let before = try attributesIfPresent(path) else { return nil }
        guard before.isRegular, let size = before.size else { throw RemoteError("上传目标必须是普通文件，不能覆盖目录或符号链接。") }
        var body = try stringBody(path); body.put32(1); body.put32(0)
        var opened = try expect(102, request(3, body)); let handle = try opened.bytes()
        defer { try? close(handle) }
        var hash = SHA256(); var next: UInt64 = 0; var hashed: UInt64 = 0
        var pending: [UInt32: (offset: UInt64, length: UInt32, block: UInt64)] = [:]
        var chunks: [UInt64: Data] = [:]; var ready = Set<UInt64>()
        func enqueue(_ offset: UInt64, _ length: UInt32, _ block: UInt64) throws {
            var read = Packet(); read.putData(handle); read.put64(offset); read.put32(length)
            pending[try sendRequest(5, read)] = (offset, length, block)
        }
        func fill() throws {
            while pending.count + ready.count < 16 && next < size {
                let length = UInt32(min(65536, size - next))
                try enqueue(next, length, next); next += UInt64(length)
            }
        }
        progress(0, size)
        do {
            try fill()
            while !pending.isEmpty {
                let (type, id, packet) = try response()
                guard let read = pending.removeValue(forKey: id) else { throw RemoteError("校验响应编号异常。") }
                var reply = try expect(103, (type, packet)); let data = try reply.bytes()
                guard !data.isEmpty, data.count <= Int(read.length) else { throw RemoteError("远程校验读取异常。") }
                chunks[read.block, default: Data()].append(data)
                if data.count < Int(read.length) {
                    try enqueue(read.offset + UInt64(data.count), read.length - UInt32(data.count), read.block)
                } else { ready.insert(read.block) }
                while ready.remove(hashed) != nil, let chunk = chunks.removeValue(forKey: hashed) {
                    hash.update(data: chunk); hashed += UInt64(chunk.count)
                }
                progress(hashed, size); try fill()
            }
        } catch { if !pending.isEmpty { cancel() }; throw error }
        let after = try attributesIfPresent(path)
        guard after?.size == before.size, after?.modified == before.modified else { throw RemoteError("远程文件在校验时发生变化，请重试。") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Snapshots and the temporary name survive retries. Never truncate the destination.
    func upload(_ local: URL, to target: String, temporary: String, expected: String?,
                verification: (String, UInt64, UInt64) -> Void = { _, _, _ in },
                progress: (UInt64, UInt64) -> Void) throws -> String {
        guard target.hasPrefix("/"), temporary != target,
              (temporary as NSString).deletingLastPathComponent == (target as NSString).deletingLastPathComponent else {
            throw RemoteError("上传临时文件必须位于目标的同一目录，且不能与目标同名。")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0
        verification("校验本地副本", 0, 0)
        let digest = try localFingerprint(local)
        func checked(_ path: String, _ stage: String) throws -> String? {
            verification(stage, 0, 0)
            return try fingerprint(path) { verification(stage, $0, $1) }
        }
        let current = try checked(target, "检查远程目标")
        if current == digest { return digest } // Reconcile a lost commit acknowledgement.
        guard current == expected else { throw TransferConflict(remoteHash: current) }
        if current != nil && !supportsAtomicReplace { throw RemoteError("服务器不支持安全替换；请选择保留两份。") }
        var offset: UInt64 = 0
        if let partial = try attributesIfPresent(temporary) {
            guard partial.isRegular, let count = partial.size, count <= UInt64(size),
                  try checked(temporary, "校验续传部分") == localFingerprint(local, limit: count) else {
                throw RemoteError("续传临时文件校验不一致，请选择重新上传；原文件未改变。")
            }
            offset = count
        }
        let permissions = try attributesIfPresent(target)?.permissions.map { $0 & 0o777 } ?? 0o600
        var body = try stringBody(temporary)
        let exists = try attributesIfPresent(temporary) != nil
        body.put32(exists ? 2 : 2 | 8 | 32)
        body.put32(4); body.put32(0o600)
        var opened = try expect(102, request(3, body)); let handle = try opened.bytes()
        var closed = false
        defer { if !closed { try? close(handle) } }
        let input = try FileHandle(forReadingFrom: local); defer { try? input.close() }
        try input.seek(toOffset: offset); progress(offset, UInt64(size))
        var submitted = offset
        var pending: [UInt32: Int] = [:]
        func fillWrites() throws {
            while pending.count < 16 && submitted < size {
                let data = try input.read(upToCount: Int(min(65536, size - submitted))) ?? Data()
                guard !data.isEmpty else { throw RemoteError("本地上传副本发生变化。") }
                var write = Packet(); write.putData(handle); write.put64(submitted); write.putData(data)
                pending[try sendRequest(6, write)] = data.count; submitted += UInt64(data.count)
            }
        }
        do {
            try fillWrites()
            while !pending.isEmpty {
                let (type, id, packet) = try response()
                guard let length = pending.removeValue(forKey: id) else { throw RemoteError("上传响应编号异常。") }
                try statusOK((type, packet)); offset += UInt64(length)
                progress(offset, size); try fillWrites()
            }
        } catch { if !pending.isEmpty { cancel() }; throw error }
        try close(handle); closed = true
        guard try checked(temporary, "校验上传内容") == digest else { throw RemoteError("上传内容校验失败，未提交到目标文件。") }
        let latest = try checked(target, "检查远程冲突")
        guard latest == expected else { throw TransferConflict(remoteHash: latest) }
        verification("正在提交", 0, 0)
        var mode = try stringBody(temporary); mode.put32(4); mode.put32(permissions)
        try statusOK(request(9, mode))
        var rename = Packet()
        if expected != nil { rename.putString("posix-rename@openssh.com") }
        rename.putString(temporary); rename.putString(target)
        try statusOK(request(expected == nil ? 18 : 200, rename))
        return digest
    }

    private func markDownloaded(_ url: URL) throws {
        let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));RemoteFinder;\(UUID().uuidString)"
        let marked = url.path.withCString { path in quarantine.withCString { value in
            setxattr(path, "com.apple.quarantine", value, strlen(value), 0, 0)
        } }
        guard marked == 0 else { throw RemoteError("无法设置 macOS 下载安全标记；下载未提交。") }
    }

    func downloadExport(_ path: String, to destination: URL, progress: (UInt64, UInt64) -> Void) throws {
        guard let attributes = try attributesIfPresent(path) else { throw RemoteError("远程项目已不存在。") }
        if attributes.isRegular { try download(path, to: destination, progress: progress); return }
        guard attributes.isDirectory else { throw RemoteError("暂不下载符号链接或特殊文件：\(path)") }
        var files: [(remote: String, relative: String, attributes: FileAttributes)] = []
        var directories: [String] = []
        var total: UInt64 = 0; var entries = 0; var pathBytes = 0
        func scan(_ remote: String, _ relative: String, _ depth: Int) throws {
            guard depth < 128 else { throw RemoteError("目录嵌套超过 128 层，请分批下载。") }
            for entry in try list(remote) {
                try checkCancellation()
                let child = (remote == "/" ? "" : remote) + "/" + entry.name
                let local = relative.isEmpty ? entry.name : relative + "/" + entry.name
                entries += 1; pathBytes += child.utf8.count + local.utf8.count
                guard entries <= 200000, pathBytes <= 64 * 1024 * 1024 else { throw RemoteError("下载目录过大，请分批拖出子目录。") }
                if entry.attributes.isDirectory {
                    directories.append(local); try scan(child, local, depth + 1)
                } else if entry.attributes.isRegular, let size = entry.attributes.size {
                    let sum = total.addingReportingOverflow(size)
                    guard !sum.overflow else { throw RemoteError("下载总大小超出支持范围。") }
                    total = sum.partialValue; files.append((child, local, entry.attributes))
                } else { throw RemoteError("目录包含符号链接或特殊文件，未下载：\(child)") }
            }
        }
        try scan(path, "", 0)
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".remotefinder-\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for directory in directories {
            try checkCancellation()
            try fm.createDirectory(at: staging.appendingPathComponent(directory), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var completed: UInt64 = 0; progress(0, total)
        for file in files {
            let current = try attributesIfPresent(file.remote)
            guard current?.isRegular == true, current?.size == file.attributes.size, current?.modified == file.attributes.modified else {
                throw RemoteError("远程目录内容在下载时发生变化，请重新拖出：\(file.remote)")
            }
            try download(file.remote, to: staging.appendingPathComponent(file.relative)) { count, _ in progress(completed + count, total) }
            completed += file.attributes.size ?? 0
        }
        try checkCancellation(); try markDownloaded(staging)
        try fm.moveItem(at: staging, to: destination)
        progress(total, total)
    }

    public func download(_ path: String, to destination: URL, progress: (UInt64, UInt64) -> Void) throws {
        let attributes = try stat(path)
        guard attributes.isRegular, let size = attributes.size else { throw RemoteError("只能打开普通文件或指向普通文件的链接。") }
        var body = try stringBody(path); body.put32(1); body.put32(0)
        var opened = try expect(102, request(3, body))
        let handle = try opened.bytes()
        defer { try? close(handle) }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteError("无法创建本地缓存文件。")
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        var pending: [UInt32: (UInt64, UInt32)] = [:]
        var offset: UInt64 = 0; var completed: UInt64 = 0
        func enqueue(_ start: UInt64, _ length: UInt32) throws {
            var body = Packet(); body.putData(handle); body.put64(start); body.put32(length)
            pending[try sendRequest(5, body)] = (start, length)
        }
        func fill() throws {
            while pending.count < 16 && offset < size {
                let length = UInt32(min(32768, size - offset))
                try enqueue(offset, length); offset += UInt64(length)
            }
        }
        do {
            try fill()
            while !pending.isEmpty {
                let (type, id, packet) = try response()
                guard let (start, requested) = pending.removeValue(forKey: id) else { throw RemoteError("SFTP 下载响应编号异常。") }
                var reply = try expect(103, (type, packet)); let data = try reply.bytes()
                guard !data.isEmpty && data.count <= Int(requested) else { throw RemoteError("SFTP 下载块长度异常。") }
                try file.seek(toOffset: start); try file.write(contentsOf: data)
                completed += UInt64(data.count)
                if data.count < requested { try enqueue(start + UInt64(data.count), requested - UInt32(data.count)) }
                try fill(); progress(completed, size)
            }
            try file.synchronize()
            let after = try stat(path)
            guard after.size == size, after.modified == attributes.modified else { throw RemoteError("远程文件在下载过程中发生了变化，请重试。") }
            // Set the download safety marker before exposing the completed file to other apps.
            try markDownloaded(partial)
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(size, size)
        } catch {
            // Outstanding reads must not leak into the next directory request.
            if !pending.isEmpty { cancel() }
            throw error
        }
    }
}
