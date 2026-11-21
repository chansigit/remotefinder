import Foundation

func entry(_ name: String, directory: Bool = false, size: UInt64 = 0) -> RemoteEntry {
    var packet = Packet(); packet.put32(13); packet.put64(size)
    packet.put32(directory ? 0o40700 : 0o100600); packet.put32(1); packet.put32(1)
    return RemoteEntry(name: name, attributes: try! FileAttributes(&packet))
}
let sample = [entry("file10", size: 10), entry("file2", size: 2), entry(".hidden"), entry("folder", directory: true), entry("中文.txt")]
let named = try ListingWorker.project(sample, query: "", showHidden: false, key: "name", ascending: true)
precondition(named.first?.name == "folder" && !named.contains { $0.name == ".hidden" })
precondition(named.firstIndex { $0.name == "file2" }! < named.firstIndex { $0.name == "file10" }!)
let sized = try ListingWorker.project(sample, query: "", showHidden: true, key: "size", ascending: false)
precondition(sized[0].name == "folder" && sized[1].name == "file10")
let filtered = try ListingWorker.project(sample, query: "FILE2", showHidden: false, key: "name", ascending: true)
precondition(filtered.count == 1)
var cancelled = false
do { _ = try ListingWorker.project(sample, query: "", showHidden: true, key: "name", ascending: true, isCancelled: { true }) }
catch { cancelled = true }
precondition(cancelled)

var cache = DirectoryCache(); cache.maxDirectories = 2
cache.insert(sample, at: "/a", now: 0); cache.insert(sample, at: "/b", now: 1)
precondition(cache.get("/a", now: 2) != nil)
cache.insert(sample, at: "/c", now: 3)
precondition(cache.get("/a", now: 4) != nil && cache.get("/b", now: 4) == nil, "evict least recently used, not the whole cache")
precondition(cache.get("/a", now: 16) == nil, "cache hits must not renew server freshness")
cache.maxCost = 1; cache.insert(sample, at: "/huge", now: 17)
precondition(cache.get("/huge", now: 18) == nil)
cache.removeAll(); precondition(cache.cost == 0)

let large = (0..<100000).map { entry("file-\(($0 * 7919) % 100000)", directory: $0 % 11 == 0, size: UInt64($0)) }
let worker = ListingWorker()
var finished = false
var pulses = 0
var lastPulse = ProcessInfo.processInfo.systemUptime
var longestGap: TimeInterval = 0
let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
    let now = ProcessInfo.processInfo.systemUptime
    longestGap = max(longestGap, now - lastPulse); lastPulse = now; pulses += 1
}
RunLoop.main.add(timer, forMode: .common)
let start = ProcessInfo.processInfo.systemUptime
worker.submit(large, query: "", showHidden: true) { result in
    precondition(Thread.isMainThread && result.count == 100000)
    precondition(result.first!.attributes.isDirectory)
    finished = true
}
let deadline = Date().addingTimeInterval(20)
while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(finished && pulses > 0 && longestGap < 1, "sorting must leave the main run loop responsive")
let elapsed = ProcessInfo.processInfo.systemUptime - start

finished = false
worker.submit(large, query: "", showHidden: true, delay: 0.1) { _ in preconditionFailure("stale search was delivered") }
worker.submit(sample, query: "FILE2", showHidden: false) { result in
    precondition(result.map { $0.name } == ["file2"]); finished = true
}
let latestDeadline = Date().addingTimeInterval(2)
while !finished && Date() < latestDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(finished, "latest query must not wait for obsolete work")
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
finished = false
var superseded = false
worker.submit(large, query: "", showHidden: true) { _ in
    precondition(!superseded, "a running obsolete sort must not replace newer results")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
    superseded = true
    worker.submit(sample, query: "中文", showHidden: true) { result in
        precondition(result.map { $0.name } == ["中文.txt"]); finished = true
    }
}
let cancellationDeadline = Date().addingTimeInterval(2)
while !finished && Date() < cancellationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(finished, "new queries must interrupt an in-progress sort")
worker.submit(large, query: "", showHidden: true) { _ in preconditionFailure("cancelled directory update was delivered") }
worker.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
timer.invalidate()
print(String(format: "PASS: 100,000 entries sorted in background in %.3fs; main-loop max gap %.1fms; latest-only search, cancellation, sort semantics, bounded LRU/TTL cache", elapsed, longestGap * 1000))
