import Foundation
import CryptoKit

struct TransferConflict: LocalizedError {
    let remoteHash: String?
    var errorDescription: String? { "远程文件已存在或已被修改，请选择保留两份、重新加载或明确覆盖。" }
}

func localFingerprint(_ url: URL, limit: UInt64? = nil) throws -> String {
    let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
    var remaining = limit ?? UInt64.max; var hash = SHA256()
    while remaining > 0 {
        let data = try input.read(upToCount: Int(min(65536, remaining))) ?? Data()
        if data.isEmpty { break }
        hash.update(data: data); remaining -= UInt64(data.count)
    }
    if limit != nil && remaining != 0 { throw RemoteError("本地文件长度不匹配。") }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func isEditableText(_ url: URL) throws -> Bool {
    let extensions = Set(["", "txt", "md", "markdown", "py", "r", "sh", "bash", "zsh", "yaml", "yml", "json", "toml", "ini", "conf", "cfg", "csv", "tsv", "log", "sql", "js", "ts", "jsx", "tsx", "c", "h", "cpp", "hpp", "swift", "rs", "go", "html", "css", "xml", "svg", "tex", "bib", "rb", "pl", "lua", "jl", "ipynb"])
    guard extensions.contains(url.pathExtension.lowercased()),
          (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max <= 5 * 1024 * 1024 else { return false }
    let data = try Data(contentsOf: url)
    return !data.contains(0) && String(data: data, encoding: .utf8) != nil
}

struct TransferItem: Codable {
    var id = UUID()
    var connection: ConnectionProfile
    var remote: String
    var local: URL
    var editing: Bool
    var snapshot: URL?
    var temporary: String
    var baseline: String?
    var observed: String?
    var conflictHash: String?
    var state = "queued"
    var detail = "等待上传"
    var attempts = 0
    var retryAt = Date.distantPast
    var phase: String?
    var completedBytes: UInt64?
    var totalBytes: UInt64?
    var isDownload: Bool?
    var percent: Int? {
        guard let completed = completedBytes, let total = totalBytes else { return nil }
        if total == 0 { return phase == nil && ["done", "watching"].contains(state) ? 100 : nil }
        return Int(min(100, max(0, (Double(completed) / Double(total) * 100).rounded(.down))))
    }
    var progressText: String {
        guard let percent = percent else { return phase ?? detail }
        return "\(phase ?? (state == "done" || state == "watching" ? "已完成" : "已传")) \(percent)%"
    }
}

final class TransferManager {
    private let queue = DispatchQueue(label: "RemoteFinder.transfers", qos: .utility)
    private var items: [TransferItem] = []
    private var localSignatures: [UUID: String] = [:]
    private let root: URL
    private let factory: (ConnectionProfile, Bool) throws -> SFTPClient
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var active: SFTPClient?
    private var stopped = false
    private var cancelledIDs = Set<UUID>()
    private var activeID: UUID?
    private var sessionConnection: ConnectionProfile?
    var onChange: (([TransferItem]) -> Void)?

    init(root: URL, factory: @escaping (ConnectionProfile, Bool) throws -> SFTPClient) {
        self.root = root; self.factory = factory
        queue.async {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let manifest = root.appendingPathComponent("transfers.json")
                if FileManager.default.fileExists(atPath: manifest.path) {
                    self.items = try JSONDecoder().decode([TransferItem].self, from: Data(contentsOf: manifest))
                    for i in self.items.indices where ["queued", "preparing"].contains(self.items[i].state) {
                        self.items[i].phase = nil; self.items[i].state = "paused"; self.items[i].detail = "应用已重启，点击重试续传"
                        if self.items[i].isDownload == true { self.items[i].detail = "下载已中断，请重新拖出文件" }
                    }
                }
                self.publish()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
            } catch { self.publishError(error) }
        }
    }

    private func publishError(_ error: Error) {
        var item = TransferItem(connection: ConnectionProfile(host: ""), remote: "传输记录", local: root, editing: false, temporary: "")
        item.state = "error"; item.detail = error.localizedDescription
        let result = items + [item]
        DispatchQueue.main.async { [weak self] in self?.onChange?(result) }
    }

    private func persist() throws {
        let file = root.appendingPathComponent("transfers.json")
        try JSONEncoder().encode(items).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func publish() {
        do { try persist() } catch { publishError(error); return }
        let result = items
        DispatchQueue.main.async { [weak self] in self?.onChange?(result) }
    }
    static func temporary(for remote: String) -> String {
        (remote as NSString).deletingLastPathComponent + "/.remotefinder-" + UUID().uuidString + ".partial"
    }
    private func snapshot(_ local: URL) throws -> URL {
        let values = try URL(fileURLWithPath: local.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteError("请选择普通文件；暂不上传文件夹或符号链接。") }
        let before = try localFingerprint(local)
        let target = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: local, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard try localFingerprint(target) == before, try localFingerprint(local) == before else {
            try? FileManager.default.removeItem(at: target)
            throw RemoteError("文件正在修改，请保存完成后重试。")
        }
        return target
    }
    func add(_ urls: [URL], connection: ConnectionProfile, directory: String) {
        queue.async {
            for url in urls {
                let remote = (directory == "/" ? "" : directory) + "/" + url.lastPathComponent
                var item = TransferItem(connection: connection, remote: remote, local: url, editing: false, temporary: Self.temporary(for: remote))
                item.state = "preparing"; item.detail = "正在准备上传副本…"
                let index = self.items.count; self.items.append(item); self.publish()
                do { self.items[index].snapshot = try self.snapshot(url); self.items[index].state = "queued"; self.items[index].detail = "等待上传" }
                catch { self.items[index].state = "error"; self.items[index].detail = error.localizedDescription }
            }
            self.publish()
        }
    }
    func watch(_ local: URL, connection: ConnectionProfile, remote: String, baseline: String) {
        queue.async {
            guard !self.items.contains(where: { $0.editing && $0.state != "stopped" && $0.connection.sameServer(as: connection) && $0.remote == remote }) else { return }
            guard self.items.filter({ $0.editing && $0.state != "stopped" }).count < 20 else { self.publishError(RemoteError("最多同时监听 20 个文本文件，请先停止不需要的同步。")); return }
            var item = TransferItem(connection: connection, remote: remote, local: local, editing: true, temporary: Self.temporary(for: remote), baseline: baseline)
            item.state = "watching"; item.detail = "监听本地保存 · 尚无修改"
            self.items.append(item); self.publish()
        }
    }
    // File promise callbacks run on a background operation queue and wait for the final file.
    func download(_ remote: String, connection: ConnectionProfile, to local: URL) throws {
        try queue.sync {
            var item = TransferItem(connection: connection, remote: remote, local: local, editing: false, temporary: "")
            item.isDownload = true; item.phase = "正在连接"; item.detail = "正在连接以下载…"
            let i = items.count; items.append(item); publish()
            defer { items[i].phase = nil; publish() }
            do {
                guard local.isFileURL else { throw RemoteError("下载目标必须是本地文件夹。") }
                lock.lock(); let stop = stopped; let previous = active; lock.unlock()
                guard !stop else { throw RemoteError("应用正在退出，请重新拖出文件。") }
                previous?.cancel(); sessionConnection = nil
                let session = try factory(connection, true)
                lock.lock(); active = session; activeID = item.id
                if stopped || cancelledIDs.contains(item.id) { session.cancel() }; lock.unlock()
                defer { session.cancel(); lock.lock(); active = nil; activeID = nil; lock.unlock() }
                try session.start()
                items[i].phase = "读取下载列表"; items[i].detail = "正在统计文件与子目录…"; publish()
                var last = Date.distantPast
                try session.downloadExport(remote, to: local) { completed, total in
                    guard completed == total || Date().timeIntervalSince(last) > 0.25 else { return }
                    last = Date(); self.items[i].phase = "下载"
                    self.items[i].completedBytes = completed; self.items[i].totalBytes = total
                    self.items[i].detail = self.items[i].progressText + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file)
                    self.publish()
                }
                items[i].state = "done"; items[i].detail = "已下载到本地 · " + local.deletingLastPathComponent().path
            } catch {
                lock.lock(); let cancelled = stopped || cancelledIDs.contains(item.id); lock.unlock()
                items[i].state = cancelled ? "stopped" : "error"
                items[i].detail = (cancelled ? "下载已取消" : error.localizedDescription) + " · 请重新拖出文件"
                throw error
            }
        }
    }
    func action(_ id: UUID, _ action: String) {
        lock.lock()
        if action == "pause" { cancelledIDs.insert(id); if activeID == id { active?.cancel() } }
        else { cancelledIDs.remove(id) }
        lock.unlock()
        queue.async {
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            if self.items[i].isDownload == true {
                if action == "pause", self.items[i].state != "done" { self.items[i].state = "stopped"; self.items[i].detail = "下载已取消 · 请重新拖出文件"; self.publish() }
                return
            }
            if action == "pause" {
                self.items[i].state = "stopped"; self.items[i].detail = "已停止 · 本地副本和续传数据保留"
            } else if action == "reload" {
                do {
                    let session = try self.factory(self.items[i].connection, true); defer { session.cancel() }
                    try session.start()
                    let downloaded = self.root.appendingPathComponent(UUID().uuidString)
                    try session.download(self.items[i].remote, to: downloaded) { _, _ in }
                    let hash = try localFingerprint(downloaded)
                    let backup = self.items[i].local.appendingPathExtension("backup-" + UUID().uuidString)
                    try FileManager.default.copyItem(at: self.items[i].local, to: backup)
                    try Data(contentsOf: downloaded).write(to: self.items[i].local, options: .atomic)
                    try? FileManager.default.removeItem(at: downloaded)
                    self.items[i].baseline = hash; self.items[i].snapshot = nil
                    self.items[i].state = "watching"; self.items[i].detail = "已重新加载 · 原本地内容保留为 backup 文件"
                } catch { self.items[i].state = "error"; self.items[i].detail = error.localizedDescription }
            } else {
                if action == "overwrite" { self.items[i].baseline = self.items[i].conflictHash }
                if action == "copy" {
                    let old = self.items[i].remote as NSString
                    self.items[i].remote = old.deletingPathExtension + "-copy-" + UUID().uuidString.prefix(8) + (old.pathExtension.isEmpty ? "" : "." + old.pathExtension)
                    self.items[i].baseline = nil
                }
                if action == "restart" || action == "copy" { self.items[i].temporary = Self.temporary(for: self.items[i].remote) }
                self.items[i].phase = nil; self.items[i].completedBytes = nil; self.items[i].totalBytes = nil
                self.items[i].attempts = 0; self.items[i].retryAt = .distantPast
                self.items[i].state = self.items[i].snapshot == nil && self.items[i].editing ? "watching" : "queued"
                self.items[i].detail = "等待重试 / 检测本地修改"
                if self.items[i].snapshot == nil && !self.items[i].editing {
                    do { self.items[i].snapshot = try self.snapshot(self.items[i].local) }
                    catch { self.items[i].state = "error"; self.items[i].detail = error.localizedDescription }
                }
            }
            self.publish()
        }
    }
    private func tick() {
        lock.lock(); let stop = stopped; lock.unlock(); if stop { return }
        for i in items.indices where items[i].editing && items[i].state == "watching" {
            do {
                let values = try URL(fileURLWithPath: items[i].local.path).resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else { throw RemoteError("自动同步文本上限为 5 MiB；请使用拖放上传。") }
                let attributes = try FileManager.default.attributesOfItem(atPath: items[i].local.path)
                let signature = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attributes[.size] ?? "")-\(attributes[.systemFileNumber] ?? "")"
                if localSignatures[items[i].id] == signature && items[i].observed == nil { continue }
                localSignatures[items[i].id] = signature
                let content = try Data(contentsOf: items[i].local)
                guard !content.contains(0), String(data: content, encoding: .utf8) != nil else { throw RemoteError("文件已不再是 UTF-8 文本，已停止自动同步。") }
                let hash = try localFingerprint(items[i].local)
                if hash == items[i].baseline { items[i].observed = nil; continue }
                if items[i].observed != hash { items[i].observed = hash; continue }
                items[i].snapshot = try snapshot(items[i].local)
                items[i].temporary = Self.temporary(for: items[i].remote)
                items[i].state = "queued"; items[i].detail = "检测到保存，等待同步"; items[i].attempts = 0
                publish()
            } catch { items[i].state = "error"; items[i].detail = error.localizedDescription; publish() }
        }
        guard let i = items.firstIndex(where: { $0.state == "queued" && $0.retryAt <= Date() }), let snapshot = items[i].snapshot else { return }
        lock.lock(); let cancelled = cancelledIDs.contains(items[i].id) || stopped; lock.unlock()
        if cancelled { return }
        items[i].phase = "正在连接"; items[i].completedBytes = nil; items[i].totalBytes = nil
        items[i].detail = "正在连接 / 校验上传内容…"; publish()
        let session: SFTPClient
        defer { lock.lock(); activeID = nil; lock.unlock() }
        do {
            try persist()
            lock.lock(); let previous = active; lock.unlock()
            if let previous = previous, previous.isUsable, sessionConnection?.sameServer(as: items[i].connection) == true {
                session = previous
                lock.lock(); activeID = items[i].id; lock.unlock()
            } else {
                previous?.cancel()
                session = try factory(items[i].connection, items[i].attempts == 0)
                lock.lock(); active = session; activeID = items[i].id; if stopped || cancelledIDs.contains(items[i].id) { session.cancel() }; lock.unlock()
                sessionConnection = items[i].connection
                try session.start()
            }
            var last = Date.distantPast
            func report(_ phase: String, _ completed: UInt64, _ total: UInt64) {
                if self.items[i].phase != phase || completed == total || Date().timeIntervalSince(last) > 0.25 {
                    last = Date(); self.items[i].phase = phase
                    self.items[i].completedBytes = completed; self.items[i].totalBytes = total
                    self.items[i].detail = self.items[i].progressText
                    if total > 0 { self.items[i].detail += " · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))" }
                    self.publish()
                }
            }
            let hash = try session.upload(snapshot, to: items[i].remote, temporary: items[i].temporary, expected: items[i].baseline,
                                          verification: report) { report("上传", $0, $1) }
            let size = (try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.uint64Value ?? 0
            items[i].completedBytes = size; items[i].totalBytes = size; items[i].phase = nil
            items[i].baseline = hash; items[i].observed = nil; items[i].snapshot = nil
            items[i].state = items[i].editing ? "watching" : "done"
            items[i].detail = "已同步到远程"; items[i].attempts = 0
            try persist()
            try? FileManager.default.removeItem(at: snapshot)
        } catch let conflict as TransferConflict {
            items[i].state = "conflict"; items[i].conflictHash = conflict.remoteHash; items[i].detail = conflict.localizedDescription
        } catch {
            items[i].attempts += 1
            lock.lock(); let failed = active; lock.unlock()
            if failed?.isUsable == false && failed?.usedSavedPassword != true && items[i].attempts < 5 {
                items[i].retryAt = Date().addingTimeInterval(pow(2, Double(items[i].attempts)))
                items[i].detail = "连接中断，稍后校验续传 · " + error.localizedDescription
            } else { items[i].state = "error"; items[i].detail = error.localizedDescription + " · 本地副本已保留" }
        }
        items[i].phase = nil
        publish()
    }
    func shutdown() {
        lock.lock(); stopped = true; active?.cancel(); lock.unlock()
        queue.async { self.timer?.cancel(); self.timer = nil }
    }
}
