import Foundation

// Submit and cancel on the main thread; only the latest request may update the UI.
final class ListingWorker {
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated; return queue
    }()
    private var current: BlockOperation?
    private enum Cancelled: Error { case request }
    deinit { current?.cancel(); queue.cancelAllOperations() }

    func cancel() { current?.cancel(); current = nil }

    func submit(_ entries: [RemoteEntry], query: String, showHidden: Bool, key: String = "name",
                ascending: Bool = true, delay: TimeInterval = 0, completion: @escaping ([RemoteEntry]) -> Void) {
        cancel()
        let operation = BlockOperation(); current = operation
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            let result = try? Self.project(entries, query: query, showHidden: showHidden, key: key,
                                           ascending: ascending, isCancelled: { operation.isCancelled })
            guard let value = result, !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current === operation, !operation.isCancelled else { return }
                self.current = nil; completion(value)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !operation.isCancelled else { return }
            self.queue.addOperation(operation)
        }
    }

    static func project(_ entries: [RemoteEntry], query: String, showHidden: Bool, key: String,
                        ascending: Bool, isCancelled: () -> Bool = { false }) throws -> [RemoteEntry] {
        var work = 0
        func checkCancellation() throws {
            if work & 255 == 0 && isCancelled() { throw Cancelled.request }
            work += 1
        }
        var result: [RemoteEntry] = []
        for entry in entries {
            try checkCancellation()
            if (showHidden || !entry.name.hasPrefix(".")) && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query)) {
                result.append(entry)
            }
        }
        try result.sort { left, right in
            try checkCancellation()
            if left.attributes.isDirectory != right.attributes.isDirectory { return left.attributes.isDirectory }
            let comparison: ComparisonResult
            switch key {
            case "size": comparison = (left.attributes.size ?? 0) == (right.attributes.size ?? 0) ? .orderedSame :
                (left.attributes.size ?? 0) < (right.attributes.size ?? 0) ? .orderedAscending : .orderedDescending
            case "date": comparison = (left.attributes.modified ?? .distantPast).compare(right.attributes.modified ?? .distantPast)
            default: comparison = left.name.localizedStandardCompare(right.name)
            }
            if comparison == .orderedSame { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return result
    }
}

struct DirectoryCache {
    private struct Value {
        let entries: [RemoteEntry]
        let loaded: TimeInterval
        var used: TimeInterval
        let cost: Int
    }
    private var values: [String: Value] = [:]
    private(set) var cost = 0
    var maxCost = 32 * 1024 * 1024
    var maxDirectories = 32

    mutating func get(_ path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [RemoteEntry]? {
        guard var value = values[path] else { return nil }
        guard now - value.loaded < 15 else { remove(path); return nil }
        value.used = now; values[path] = value
        return value.entries
    }
    mutating func insert(_ entries: [RemoteEntry], at path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        remove(path)
        let size = entries.reduce(0) { $0 + $1.name.utf8.count + 128 }
        guard size <= maxCost else { return }
        while !values.isEmpty && (cost + size > maxCost || values.count >= maxDirectories) {
            if let oldest = values.min(by: { $0.value.used < $1.value.used })?.key { remove(oldest) }
        }
        values[path] = Value(entries: entries, loaded: now, used: now, cost: size); cost += size
    }
    private mutating func remove(_ path: String) { if let old = values.removeValue(forKey: path) { cost -= old.cost } }
    mutating func removeAll() { values.removeAll(); cost = 0 }
}
