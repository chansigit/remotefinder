import Foundation
import Darwin

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
    public func arguments() throws -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              !user.hasPrefix("-"), !user.contains("\0"), !user.contains("\n"),
              !path.contains("\0") else { throw RemoteError("请输入有效的主机名或 SSH 配置别名；用户名请填在单独的输入框。") }
        var args = ["-T", "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask",
                    "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"]
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
    private var started = false

    public init(profile: ConnectionProfile, askpass: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try profile.arguments()
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = "RemoteFinder"
        process.environment = env
    }

    // Used by integration tests with the real local OpenSSH SFTP server.
    init(serverExecutable: String, arguments: [String] = []) {
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
        lock.lock()
        if cancelled { lock.unlock(); throw RemoteError("已取消。") }
        do { try process.run(); started = true; lock.unlock() }
        catch { lock.unlock(); throw error }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        var hello = Packet(); hello.putByte(1); hello.put32(3)
        try send(hello.data)
        var reply = try receive()
        guard try reply.byte() == 2, try reply.uint32() == 3 else { throw RemoteError("服务器未提供 SFTP v3。") }
        timeout = 30
    }

    public func cancel() {
        lock.lock(); cancelled = true
        if started && process.isRunning { process.terminate() }
        lock.unlock()
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

    private func wait(_ fd: Int32, _ events: Int16, until deadline: Date) throws {
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw RemoteError("已取消。") }
            guard Date() < deadline else { cancel(); throw RemoteError("服务器响应超时，请重新连接。") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno != EINTR { throw RemoteError("SSH 管道读取失败。") }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw RemoteError("SSH 连接已关闭。") }
            }
        }
    }

    private func send(_ data: Data) throws {
        var frame = Packet(); frame.put32(UInt32(data.count)); frame.data.append(data)
        let fd = input.fileHandleForWriting.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        try frame.data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { throw RemoteError("SSH 连接写入失败。") }
            }
        }
    }

    private func read(_ count: Int, until deadline: Date) throws -> Data {
        var data = Data(count: count)
        let fd = output.fileHandleForReading.fileDescriptor
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(fd, Int16(POLLIN), until: deadline)
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received > 0 { offset += received }
                else if received == 0 { throw RemoteError("SSH 连接已关闭。") }
                else if errno != EAGAIN && errno != EINTR { throw RemoteError("SSH 连接读取失败。") }
            }
        }
        return data
    }

    private func receive() throws -> Packet {
        let deadline = Date().addingTimeInterval(timeout)
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
        var reply = try receive()
        let type = try reply.byte(); let id = try reply.uint32()
        return (type, id, reply)
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
            let code = try status.uint32(); let message = try status.string()
            throw RemoteError("SFTP \(code)：\(message)")
        }
        throw RemoteError("服务器返回了不符合预期的 SFTP 响应。")
    }

    private func stringBody(_ string: String) throws -> Packet {
        guard !string.contains("\0"), string.utf8.count <= 65536 else { throw RemoteError("远程路径无效或过长。") }
        var body = Packet(); body.putString(string); return body
    }

    public func realpath(_ path: String) throws -> String {
        var reply = try expect(104, request(16, stringBody(path)))
        guard try reply.uint32() == 1 else { throw RemoteError("服务器返回了无效的路径。") }
        return try reply.string()
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
            for _ in 0..<count {
                let name = try batch.string(); _ = try batch.bytes()
                let attributes = try FileAttributes(&batch)
                if name == "." || name == ".." { continue }
                guard RemoteEntry.isSafeName(name) else { throw RemoteError("服务器返回了不安全的文件名。") }
                entries.append(RemoteEntry(name: name, attributes: attributes))
            }
        }
        return entries.sorted {
            if $0.attributes.isDirectory != $1.attributes.isDirectory { return $0.attributes.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(size, size)
        } catch {
            // Outstanding reads must not leak into the next directory request.
            if !pending.isEmpty { cancel() }
            throw error
        }
    }
}
