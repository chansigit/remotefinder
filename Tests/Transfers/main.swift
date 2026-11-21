import Foundation
import Darwin
signal(SIGPIPE, SIG_IGN)
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw RemoteError("FAIL: " + message) }
}
func rejected(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw RemoteError("FAIL: should reject " + message)
}
func pump(_ duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
func waitFor(_ message: String, _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(15)
    while Date() < end && !condition() { pump(0.05) }
    try check(condition(), message)
}
func tests() throws {
    var progressItem = TransferItem(connection: ConnectionProfile(host: "fixture"), remote: "/file", local: URL(fileURLWithPath: "/tmp/file"), editing: false, temporary: "/partial")
    progressItem.phase = "上传"; progressItem.completedBytes = 42; progressItem.totalBytes = 100
    try check(progressItem.percent == 42 && progressItem.progressText == "上传 42%", "structured upload percentage")
    progressItem.phase = "校验上传内容"; progressItem.completedBytes = 100
    try check(progressItem.progressText == "校验上传内容 100%" && progressItem.state == "queued", "validation is not mislabeled as completed upload")
    progressItem.totalBytes = 0
    try check(progressItem.percent == nil, "unknown or zero-length validation uses indeterminate progress")
    progressItem.phase = nil; progressItem.state = "done"
    try check(progressItem.percent == 100, "confirmed empty upload completes at 100 percent")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progressItem)) as! [String: Any]
    for key in ["phase", "completedBytes", "totalBytes"] { legacy.removeValue(forKey: key) }
    let restoredProgress = try JSONDecoder().decode(TransferItem.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(restoredProgress.percent == nil, "old transfer manifests remain readable")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("RemoteFinder-transfers-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let hashSource = root.appendingPathComponent("hash-source")
    try Data((0..<700123).map { UInt8(truncatingIfNeeded: $0 * 31) }).write(to: hashSource)
    let reordered = SFTPClient(serverExecutable: "/usr/bin/python3", arguments: ["Tests/short_read_server.py", "--require-pipeline"])
    try reordered.start(); defer { reordered.cancel() }
    var hashedBytes: UInt64 = 0
    let actualHash = try reordered.fingerprint("/fixture") { completed, total in
        precondition(completed >= hashedBytes && completed <= total); hashedBytes = completed
    }
    try check(actualHash == localFingerprint(hashSource) && hashedBytes == 700123, "pipelined checksum handles short and reordered responses in bounded blocks")
    let local = root.appendingPathComponent("local.txt")
    let target = root.appendingPathComponent("remote.txt")
    let partial = root.appendingPathComponent("partial")
    let data = Data(repeating: 65, count: 2 * 1024 * 1024 + 123)
    try data.write(to: local)
    let first = SFTPClient(serverExecutable: "/usr/libexec/sftp-server"); try first.start()
    try rejected("interrupted upload") {
        _ = try first.upload(local, to: target.path, temporary: partial.path, expected: nil) { done, _ in if done >= 131072 { first.cancel() } }
    }
    try check(!fm.fileExists(atPath: target.path), "interrupted new upload never exposes a partial destination")
    let partialSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    try check(partialSize >= 131072 && partialSize < data.count, "partial bytes survive disconnect")
    let session = SFTPClient(serverExecutable: "/usr/libexec/sftp-server"); try session.start(); defer { session.cancel() }
    var resumed: UInt64?
    let digest = try session.upload(local, to: target.path, temporary: partial.path, expected: nil) { done, _ in if resumed == nil { resumed = done } }
    try check(resumed == UInt64(partialSize), "resume begins at verified remote offset")
    try check(try Data(contentsOf: target) == data, "resumed payload matches exactly")
    try check(try session.upload(local, to: target.path, temporary: partial.path, expected: nil) { _, _ in } == digest, "lost commit acknowledgement is reconciled")
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
    try Data("new text\r\n中文".utf8).write(to: local)
    try rejected("existing target needs explicit consent") { _ = try session.upload(local, to: target.path, temporary: partial.path, expected: nil) { _, _ in } }
    try check(try Data(contentsOf: target) == data, "conflict preserves existing remote data")
    var stages = Set<String>()
    let newHash = try session.upload(local, to: target.path, temporary: partial.path, expected: digest, verification: { stage, done, total in
        stages.insert(stage); precondition(done <= total)
    }) { _, _ in }
    try check(stages.contains("校验上传内容") && stages.contains("正在提交"), "verification and commit stages are reported")
    try check(try Data(contentsOf: target) == Data(contentsOf: local), "atomic replacement preserves UTF8 and CRLF")
    try check((try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640, "replacement preserves permission bits")
    try Data("someone else".utf8).write(to: target)
    try rejected("concurrent remote change") { _ = try session.upload(local, to: target.path, temporary: partial.path, expected: newHash) { _, _ in } }
    try Data("corrupt".utf8).write(to: partial)
    let otherTarget = root.appendingPathComponent("other.txt")
    try rejected("corrupt resume prefix") { _ = try session.upload(local, to: otherTarget.path, temporary: partial.path, expected: nil) { _, _ in } }
    try check(!fm.fileExists(atPath: otherTarget.path), "bad resume cannot create destination")
    try fm.removeItem(at: partial)
    try Data().write(to: local)
    _ = try session.upload(local, to: otherTarget.path, temporary: partial.path, expected: nil) { _, _ in }
    try check(try Data(contentsOf: otherTarget).isEmpty, "zero byte upload")
    let link = root.appendingPathComponent("link")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    try rejected("symlink overwrite") { _ = try session.upload(local, to: link.path, temporary: partial.path, expected: nil) { _, _ in } }

    let state = root.appendingPathComponent("queue")
    let directory = root.appendingPathComponent("destination")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let manager = TransferManager(root: state) { _, _ in SFTPClient(serverExecutable: "/usr/libexec/sftp-server") }
    defer { manager.shutdown() }
    var items: [TransferItem] = []
    manager.onChange = { items = $0 }
    let connection = ConnectionProfile(host: "fixture")
    try Data("original".utf8).write(to: local)
    manager.add([local], connection: connection, directory: directory.path)
    try waitFor("queued upload completes") { items.first?.state == "done" }
    let watched = directory.appendingPathComponent(local.lastPathComponent)
    manager.watch(local, connection: connection, remote: watched.path, baseline: try localFingerprint(local))
    try waitFor("editing registered") { items.count == 2 }
    let editID = items[1].id
    try Data("atomic save one".utf8).write(to: local, options: .atomic)
    try waitFor("editor atomic save synchronized") { (try? Data(contentsOf: watched)) == Data("atomic save one".utf8) && items.last?.state == "watching" }
    for value in ["two", "three", "latest"] { try Data(value.utf8).write(to: local, options: .atomic) }
    try waitFor("rapid saves coalesce to latest content") { (try? Data(contentsOf: watched)) == Data("latest".utf8) }
    try Data("remote edit".utf8).write(to: watched)
    try Data("local edit".utf8).write(to: local, options: .atomic)
    try waitFor("external modification pauses autosync") { items.last?.state == "conflict" }
    try check(try Data(contentsOf: watched) == Data("remote edit".utf8), "autosync conflict does not overwrite")
    manager.action(editID, "overwrite")
    try waitFor("explicit conflict resolution syncs") { items.last?.state == "watching" && (try? Data(contentsOf: watched)) == Data("local edit".utf8) }
    manager.action(editID, "pause")
    try waitFor("stop editing") { items.last?.state == "stopped" }
    try Data("do not upload".utf8).write(to: local, options: .atomic); pump(2.5)
    try check(try Data(contentsOf: watched) == Data("local edit".utf8), "stopped watcher stays stopped")
    manager.shutdown(); pump(0.2)
    let restored = TransferManager(root: state) { _, _ in SFTPClient(serverExecutable: "/usr/libexec/sftp-server") }
    defer { restored.shutdown() }
    var restoredItems: [TransferItem] = []; restored.onChange = { restoredItems = $0 }
    try waitFor("transfer history survives restart") { restoredItems.count == 2 }
    try check(restoredItems.last?.state == "stopped", "stop state survives restart")
    let restartState = root.appendingPathComponent("restart-queue")
    try fm.createDirectory(at: restartState, withIntermediateDirectories: true)
    let frozen = root.appendingPathComponent("frozen")
    try data.write(to: frozen)
    let resumedTarget = root.appendingPathComponent("after-restart")
    let savedPartial = root.appendingPathComponent("saved-partial")
    try data.prefix(65536).write(to: savedPartial)
    let savedJob = TransferItem(connection: connection, remote: resumedTarget.path, local: frozen, editing: false, snapshot: frozen, temporary: savedPartial.path)
    try JSONEncoder().encode([savedJob]).write(to: restartState.appendingPathComponent("transfers.json"))
    var attempts = 0
    let restarted = TransferManager(root: restartState) { _, _ in
        attempts += 1
        if attempts == 1 { return SFTPClient(serverExecutable: "/usr/bin/python3", arguments: ["Tests/fault_server.py", "disconnect"], timeout: 0.5) }
        return SFTPClient(serverExecutable: "/usr/libexec/sftp-server")
    }
    defer { restarted.shutdown() }
    var restartedItems: [TransferItem] = []; restarted.onChange = { restartedItems = $0 }
    try waitFor("unfinished job restored paused") { restartedItems.first?.state == "paused" }
    restarted.action(savedJob.id, "retry")
    try waitFor("transient failure automatically retries persisted partial") { restartedItems.first?.state == "done" }
    try check(attempts == 2, "bounded automatic reconnect used a fresh session")
    try check(try Data(contentsOf: resumedTarget) == data, "resumed after application restart")
    let pdf = root.appendingPathComponent("fake.pdf"); try Data("ASCII PDF".utf8).write(to: pdf)
    try check(try !isEditableText(pdf), "non-text extension does not silently enable sync")
    try check(try isEditableText(local), "UTF8 text supports autosync")
    let tree = root.appendingPathComponent("tree")
    try fm.createDirectory(at: tree.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
    try data.write(to: tree.appendingPathComponent("nested/中文 file.bin"))
    try Data("hidden".utf8).write(to: tree.appendingPathComponent(".hidden"))
    try Data().write(to: tree.appendingPathComponent("zero"))
    let exported = root.appendingPathComponent("exported")
    var exportCount: UInt64 = 0
    try session.downloadExport(tree.path, to: exported) { done, total in
        precondition(done >= exportCount && done <= total); exportCount = done
    }
    try check(exportCount == UInt64(data.count + 6), "recursive progress aggregates all bytes")
    try check(try Data(contentsOf: exported.appendingPathComponent("nested/中文 file.bin")) == data, "recursive bytes and Unicode names preserved")
    try check(try Data(contentsOf: exported.appendingPathComponent(".hidden")) == Data("hidden".utf8), "recursive download includes hidden files")
    try check(fm.fileExists(atPath: exported.appendingPathComponent("nested/empty").path), "empty directories preserved")
    try check(try Data(contentsOf: exported.appendingPathComponent("zero")).isEmpty, "empty files preserved")
    try check(exported.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) } > 0, "downloaded folder has quarantine metadata")
    try rejected("existing local directory is never merged or overwritten") { try session.downloadExport(tree.path, to: exported) { _, _ in } }
    try fm.createSymbolicLink(atPath: tree.appendingPathComponent("loop").path, withDestinationPath: tree.path)
    let unsafe = root.appendingPathComponent("unsafe-export")
    try rejected("recursive symlink cannot loop or escape source") { try session.downloadExport(tree.path, to: unsafe) { _, _ in } }
    try check(!fm.fileExists(atPath: unsafe.path), "unsupported entry cannot publish incomplete folder")
    try fm.removeItem(at: tree.appendingPathComponent("loop"))
    let cancelled = SFTPClient(serverExecutable: "/usr/libexec/sftp-server"); try cancelled.start()
    try rejected("recursive cancellation") { try cancelled.downloadExport(tree.path, to: unsafe) { done, _ in if done > 0 { cancelled.cancel() } } }
    try check(!fm.fileExists(atPath: unsafe.path), "cancelled folder is not published")
    try check(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".partial") }, "recursive staging cleaned on error and cancel")
    let emptyFolder = root.appendingPathComponent("empty-folder")
    try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: false)
    try session.downloadExport(emptyFolder.path, to: root.appendingPathComponent("empty-export")) { done, total in precondition(done == 0 && total == 0) }
    print("PASS: real SFTP upload, cancellation and verified offset resume, commit reconciliation, atomic replacement, permissions, conflicts, corrupt partials, empty files, symlinks; real local atomic saves, rapid saves, conflict resolution, stop and persisted queue")
}
do { try tests() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
