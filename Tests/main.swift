import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw RemoteError("FAIL: " + message) }
    checks += 1
}
func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { checks += 1; return }
    throw RemoteError("FAIL: should reject " + message)
}

func test() throws {
    let path = "/srv/example/projects/team/workspace/demo-training/experiments"
    let crumbs = RemotePathComponent.components(of: path)
    try check(crumbs.first == RemotePathComponent(name: "/", path: "/"), "breadcrumb has navigable root")
    try check(crumbs.last?.path == path && crumbs.count == 8, "every directory is a separate breadcrumb")
    try check(crumbs[4].path == "/srv/example/projects/team", "ancestor navigation uses full prefix")
    try check(RemotePathComponent.components(of: "/").count == 1, "root path has one breadcrumb")
    try check(RemotePathComponent.components(of: "").isEmpty, "disconnected path has no breadcrumbs")
    try check(RemotePathComponent.components(of: "/中文/space # %20/").last?.path == "/中文/space # %20", "remote names preserved without URL decoding")
    try check(compactPathIndices(widths: [40, 70, 80, 90], available: 300) == [0, 1, 2, 3], "wide path shows all ancestors")
    try check(compactPathIndices(widths: [40, 70, 80, 90], available: 170) == [0, -1, 3], "compact path preserves root and current directory")
    try check(compactPathIndices(widths: [40, 70, 80, 90], available: 250) == [0, -1, 2, 3], "compact path prioritizes nearest ancestors")
    let arguments = try ConnectionProfile(host: "my-cluster", user: "researcher", port: "2222").arguments()
    try check(arguments.suffix(3) == ["-s", "my-cluster", "sftp"], "SSH subsystem arguments")
    try check(arguments.contains("StrictHostKeyChecking=ask"), "host identity verification")
    try rejects("option injection") { _ = try ConnectionProfile(host: "-oProxyCommand=bad").arguments() }
    try rejects("shell host syntax") { _ = try ConnectionProfile(host: "a;touch pwned").arguments() }
    try rejects("invalid port") { _ = try ConnectionProfile(host: "example", port: "65536").arguments() }
    try check(try ConnectionProfile(host: "::1").arguments().contains("::1"), "IPv6")
    for name in ["..", ".", "a/b", "", "bad\0name"] { try check(!RemoteEntry.isSafeName(name), "unsafe filename") }
    try check(RemoteEntry.isSafeName("中文 ' $() \n.txt"), "legal POSIX filename")
    var packet = Packet(); packet.putByte(103); packet.put32(UInt32.max); packet.put64(UInt64.max); packet.putString("中文 空格\n")
    try check(try packet.byte() == 103, "byte codec")
    try check(try packet.uint32() == UInt32.max, "uint32 codec")
    try check(try packet.uint64() == UInt64.max, "uint64 codec")
    try check(try packet.string() == "中文 空格\n", "UTF-8 codec")
    try rejects("truncated packet") { _ = try packet.uint32() }
    var malformed = Packet(Data([0, 0, 0, 8, 1]))
    try rejects("oversized string") { _ = try malformed.bytes() }
    var invalidUTF8 = Packet(Data([0, 0, 0, 1, 255]))
    try rejects("invalid UTF8") { _ = try invalidUTF8.string() }
    var attributes = Packet(); attributes.put32(0x10)
    try rejects("unknown attributes") { _ = try FileAttributes(&attributes) }

    let suite = "RemoteFinder-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var saved = SavedLocation(name: "实验结果", connection: ConnectionProfile(host: "cluster", path: "/data/results"))
    SavedLocation.save([saved], to: defaults)
    try check(SavedLocation.load(from: defaults) == [saved], "bookmarks survive reload")
    saved.name = "新的收藏名称"
    SavedLocation.save([saved], to: defaults)
    try check(SavedLocation.load(from: defaults).first?.name == saved.name, "bookmark rename persists")
    try check(SavedLocation.load(from: defaults).first?.connection.path == "/data/results", "bookmark rename preserves remote path")
    SavedLocation.save([], to: defaults)
    try check(SavedLocation.load(from: defaults).isEmpty, "bookmark removal persists")
    SavedLocation.save([saved], key: "savedConnections", to: defaults)
    try check(SavedLocation.load(key: "savedConnections", from: defaults) == [saved], "named connection saved before login")
    try check(SavedLocation.load(from: defaults).isEmpty, "saved connections and directory bookmarks remain separate")
    saved.name = "服务器新名字"; saved.connection.port = "2222"
    SavedLocation.save([saved], key: "savedConnections", to: defaults)
    try check(SavedLocation.load(key: "savedConnections", from: defaults).first?.connection.port == "2222", "edited connection settings persist")
    try check(replacingRemotePath("/data/a/child", from: "/data/a", to: "/data/new") == "/data/new/child", "renamed parent updates descendant bookmark")
    try check(replacingRemotePath("/data/a", from: "/data/a", to: "/data/new") == "/data/new", "renamed directory updates exact bookmark")
    try check(replacingRemotePath("/data/abc", from: "/data/a", to: "/data/new") == "/data/abc", "rename respects component boundary")
    try check(!ConnectionProfile(host: "one").sameServer(as: ConnectionProfile(host: "two")), "bookmarks stay on their server")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("RemoteFinder-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let name = "数据 ' \" $() [test]\n.csv"
    let payload = Data((0..<(2 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0 * 31) })
    try payload.write(to: source.appendingPathComponent(name))
    try Data().write(to: source.appendingPathComponent("empty"))
    try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
    try fm.createDirectory(at: source.appendingPathComponent("folder"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("linked folder").path, withDestinationPath: source.appendingPathComponent("folder").path)
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("linked file").path, withDestinationPath: source.appendingPathComponent(name).path)
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("broken").path, withDestinationPath: source.appendingPathComponent("missing").path)
    for i in 0..<1200 { try Data().write(to: source.appendingPathComponent("file-\(i).txt")) }
    let server = SFTPClient(serverExecutable: "/usr/libexec/sftp-server")
    defer { server.cancel() }
    try server.start()
    let canonical = try server.realpath(source.path)
    let before = Date()
    let files = try server.list(canonical)
    let duration = Date().timeIntervalSince(before)
    try check(files.count == 1207, "multi-packet directory listing")
    try check(files.first?.name == "folder", "folders first")
    try check(files.contains { $0.name == name && $0.attributes.size == UInt64(payload.count) }, "exact special filename and size")
    try check(files.contains { $0.name == "linked folder" && $0.attributes.isLink }, "link metadata")
    try check(try server.stat(source.appendingPathComponent("linked folder").path).isDirectory, "follow directory symlink")
    try rejects("broken symlink") { _ = try server.stat(source.appendingPathComponent("broken").path) }
    try rejects("missing directory") { _ = try server.list(source.appendingPathComponent("missing").path) }
    var downloaded: UInt64 = 0
    let destination = root.appendingPathComponent("download.csv")
    try server.download(source.appendingPathComponent("linked file").path, to: destination) { count, total in
        precondition(count >= downloaded && count <= total); downloaded = count
    }
    try check(try Data(contentsOf: destination) == payload, "pipelined download byte equality")
    try check(downloaded == payload.count, "download progress reaches total")
    let empty = root.appendingPathComponent("empty")
    try server.download(source.appendingPathComponent("empty").path, to: empty) { _, _ in }
    try check(try Data(contentsOf: empty).isEmpty, "empty download")
    try rejects("directory download") { try server.download(source.appendingPathComponent("folder").path, to: root.appendingPathComponent("bad")) { _, _ in } }
    try rejects("overwriting existing cache") { try server.download(source.appendingPathComponent("empty").path, to: destination) { _, _ in } }
    try check(try Data(contentsOf: destination) == payload, "existing local file preserved")
    try check(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".partial") }, "partial files cleaned up")
    try check(try server.list(canonical).count == 1207, "session remains synchronized after errors")
    let renamed = "重命名 ' \" $() 文件.csv"
    try server.rename(in: canonical, from: name, to: renamed)
    try check(try Data(contentsOf: source.appendingPathComponent(renamed)) == payload, "remote rename preserves file contents")
    try check(!fm.fileExists(atPath: source.appendingPathComponent(name).path), "old filename removed after rename")
    try rejects("existing destination") { try server.rename(in: canonical, from: renamed, to: "empty") }
    try check(try Data(contentsOf: source.appendingPathComponent("empty")).isEmpty, "rename collision preserves target")
    try check(try Data(contentsOf: source.appendingPathComponent(renamed)) == payload, "rename collision preserves source")
    try rejects("path traversal name") { try server.rename(in: canonical, from: renamed, to: "../outside") }
    try rejects("empty filename") { try server.rename(in: canonical, from: renamed, to: "") }
    try rejects("missing rename source") { try server.rename(in: canonical, from: "absent", to: "new") }
    try server.rename(in: canonical, from: renamed, to: name)
    try server.rename(in: canonical, from: "folder", to: "renamed folder")
    try check(try server.stat(canonical + "/renamed folder").isDirectory, "directory rename")
    try rejects("existing directory") { try server.rename(in: canonical, from: "renamed folder", to: "linked folder") }
    try server.rename(in: canonical, from: "renamed folder", to: "folder")
    try server.rename(in: canonical, from: "linked file", to: "renamed link")
    try check(try fm.destinationOfSymbolicLink(atPath: canonical + "/renamed link") == source.appendingPathComponent(name).path, "rename link itself without renaming its target")
    try check(try Data(contentsOf: source.appendingPathComponent(name)) == payload, "symbolic link target preserved")
    try server.rename(in: canonical, from: "renamed link", to: "linked file")
    try check(try server.list(canonical).count == 1207, "rename errors leave session usable")
    server.cancel()
    try rejects("cancelled session") { _ = try server.list(canonical) }

    let blocked = SFTPClient(serverExecutable: "/bin/sleep", arguments: ["10"])
    let cancelStart = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { blocked.cancel() }
    try rejects("cancelled handshake") { try blocked.start() }
    try check(Date().timeIntervalSince(cancelStart) < 2, "cancellation interrupts stalled server")
    let shortServer = SFTPClient(serverExecutable: "/usr/bin/python3", arguments: ["Tests/short_read_server.py"])
    defer { shortServer.cancel() }
    try shortServer.start()
    let shortDestination = root.appendingPathComponent("short-read.bin")
    try shortServer.download("file", to: shortDestination) { _, _ in }
    let expected = Data((0..<700123).map { UInt8(truncatingIfNeeded: $0 * 31) })
    try check(try Data(contentsOf: shortDestination) == expected, "short and out-of-order pipeline responses")
    print("PASS: \(checks) checks; real OpenSSH SFTP server; 1,207 entries in \(String(format: "%.3f", duration))s; 2 MiB exact download; short/out-of-order replies")
}

do { try test() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
