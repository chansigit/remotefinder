import AppKit
import Darwin

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
var testErrors: [String] = []
var automaticAttempts = 0
var failAutomatic = false
func testSession(profile: ConnectionProfile, askpass: String, interactive: Bool = true) throws -> SFTPClient {
    if !interactive {
        automaticAttempts += 1
        if failAutomatic {
            return SFTPClient(serverExecutable: "/usr/bin/python3", arguments: ["Tests/fault_server.py", "disconnect"], timeout: 0.5)
        }
    }
    return SFTPClient(serverExecutable: "/usr/libexec/sftp-server")
}
func pump(_ duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func waitFor(_ description: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !condition() && Date() < end { pump(0.01) }
    precondition(condition(), description)
}
final class FileDrop: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFinder-recovery-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let controller = BrowserController()
let profile = ConnectionProfile(host: "local-fixture", path: root.path)
controller.connect(profile)
waitFor("initial connection") { !controller.busy && !controller.path.isEmpty }
let original = controller.path

controller.client!.cancel()
controller.navigate("child")
waitFor("failed navigation is replayed on a fresh session") { !controller.busy && controller.path == original + "/child" }
precondition(automaticAttempts == 1 && controller.backHistory == [original])
precondition(testErrors.isEmpty)

controller.search.stringValue = "keep-search"
controller.client!.cancel()
controller.connectionMonitor!.fire()
waitFor("idle connection restores directory") { !controller.busy && controller.client?.isUsable == true }
precondition(automaticAttempts == 2 && controller.path == original + "/child")
precondition(controller.search.stringValue == "keep-search")

var reads = 0
controller.run("read fixture", retryRead: true) { session -> String in
    reads += 1
    session.cancel()
    throw RemoteError("lost reply")
} completion: { _ in preconditionFailure("failed read completed") }
waitFor("read retry is bounded") { reads == 2 && !controller.busy }
pump(0.1)
precondition(automaticAttempts == 3 && controller.connectionMonitor == nil)

controller.connect(profile)
waitFor("manual connection after failure") { !controller.busy && controller.client?.isUsable == true }
var mutations = 0
controller.run("rename fixture", mutation: true) { session in
    mutations += 1
    session.cancel()
    throw RemoteError("lost rename response")
} completion: { _ in preconditionFailure("failed rename completed") }
waitFor("mutation recovery") { automaticAttempts == 4 && !controller.busy }
precondition(mutations == 1 && testErrors.contains { $0.contains("重命名结果未确认") })

failAutomatic = true
controller.client!.cancel()
controller.connectionMonitor!.fire()
waitFor("background failure budget") { automaticAttempts == 9 && !controller.busy }
precondition(controller.path == original && controller.connectionMonitor == nil)
precondition(controller.status.stringValue.contains("自动重连未成功"))

failAutomatic = false
controller.connect(profile)
waitFor("reconnect before cancellation") { !controller.busy && controller.client?.isUsable == true }
controller.client!.cancel()
controller.connectionMonitor!.fire()
controller.disconnect()
pump(0.3)
precondition(automaticAttempts == 9 && controller.client == nil && controller.path.isEmpty)

controller.connect(profile)
waitFor("connect before server switch") { !controller.busy && controller.client?.isUsable == true }
controller.client!.cancel()
controller.connectionMonitor!.fire()
controller.connect(ConnectionProfile(host: "second-fixture", path: root.appendingPathComponent("child").path))
waitFor("new connection supersedes queued recovery") { !controller.busy && controller.path == original + "/child" }
pump(0.3)
precondition(automaticAttempts == 9 && controller.profile?.host == "second-fixture")
let dropFile = root.appendingPathComponent("dragged.txt")
try Data("drop fixture".utf8).write(to: dropFile)
let drop = FileDrop(); drop.draggingPasteboard.writeObjects([dropFile as NSURL])
precondition(controller.tableView(controller.table, validateDrop: drop, proposedRow: -1, proposedDropOperation: .above) == .copy)
precondition(controller.tableView(controller.table, acceptDrop: drop, row: -1, dropOperation: .above))
precondition(controller.transferWindow == nil, "drop upload stays in background")
waitFor("native file URL drop uploads into empty current folder") { FileManager.default.fileExists(atPath: root.appendingPathComponent("child/dragged.txt").path) }
waitFor("upload refresh finishes before navigating") { controller.transferItems.first?.state == "done" && !controller.busy && !controller.filtering }
controller.navigate(original)
waitFor("directory row is available") { !controller.busy && !controller.filtering && controller.path == original }
let folderRow = controller.visible.firstIndex(where: { $0.name == "child" })!
let secondFile = root.appendingPathComponent("second.txt"); try Data("folder drop".utf8).write(to: secondFile)
let secondDrop = FileDrop(); secondDrop.draggingPasteboard.writeObjects([secondFile as NSURL])
precondition(controller.tableView(controller.table, validateDrop: secondDrop, proposedRow: folderRow, proposedDropOperation: .on) == .copy)
precondition(controller.tableView(controller.table, acceptDrop: secondDrop, row: folderRow, dropOperation: .on))
waitFor("drop onto folder row uses that folder") { FileManager.default.fileExists(atPath: root.appendingPathComponent("child/second.txt").path) }
waitFor("folder upload completes before dragging out") { controller.transferItems.last?.state == "done" && !controller.busy && !controller.filtering }
let exportFolder = root.appendingPathComponent("exports")
try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
let fileRow = controller.visible.firstIndex(where: { $0.name == "dragged.txt" })!
let filePromise = controller.tableView(controller.table, pasteboardWriterForRow: fileRow) as! NSFilePromiseProvider
let folderPromise = controller.tableView(controller.table, pasteboardWriterForRow: folderRow) as! NSFilePromiseProvider
precondition(folderPromise.fileType == "public.folder")
precondition(controller.filePromiseProvider(filePromise, fileNameForType: filePromise.fileType) == "dragged.txt")
precondition(controller.operationQueue(for: filePromise) !== OperationQueue.main)
let exportBoard = NSPasteboard.withUniqueName()
precondition(exportBoard.writeObjects([filePromise, folderPromise]))
let receivers = exportBoard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as! [NSFilePromiseReceiver]
precondition(receivers.count == 2, "native pasteboard exposes both promises")
controller.disconnect() // Promises keep the original server/path when the browser changes.
var exports = 0; var exportErrors: [Error] = []
for promise in [filePromise, folderPromise] {
    let name = controller.filePromiseProvider(promise, fileNameForType: promise.fileType)
    controller.operationQueue(for: promise).addOperation {
        controller.filePromiseProvider(promise, writePromiseTo: exportFolder.appendingPathComponent(name)) { error in
            DispatchQueue.main.async { exports += 1; if let error = error { exportErrors.append(error) } }
        }
    }
}
waitFor("file promise callbacks download file and recursive folder") { exports == 2 }
precondition(exportErrors.isEmpty, "file promises complete without errors: \(exportErrors)")
let exportedFile = try Data(contentsOf: exportFolder.appendingPathComponent("dragged.txt"))
precondition(exportedFile == Data("drop fixture".utf8))
let exportedChild = try Data(contentsOf: exportFolder.appendingPathComponent("child/second.txt"))
precondition(exportedChild == Data("folder drop".utf8))
precondition(controller.transferItems.filter { $0.isDownload == true && $0.state == "done" && $0.percent == 100 }.count == 2)
precondition(controller.transferWindow == nil, "downloads remain in background")
precondition(controller.transferItems.filter { $0.isDownload == true }.allSatisfy { !$0.editing }, "dragged text never enables autosync")

final class ClickedTable: NSTableView {
    var hitRow = -1
    override var clickedRow: Int { hitRow }
}
controller.connect(profile)
waitFor("ready for double-click regression") { !controller.busy && !controller.filtering && controller.path == original }
let selectedFolder = controller.visible.firstIndex(where: { $0.name == "child" })!
let clickedFolder = controller.visible.firstIndex(where: { $0.name == "exports" })!
controller.table.selectRowIndexes(IndexSet(integer: selectedFolder), byExtendingSelection: false)
let clickSource = ClickedTable()
precondition(app.sendAction(controller.table.doubleAction!, to: controller, from: clickSource))
pump(0.1)
precondition(controller.path == original && !controller.busy, "double-clicking empty space must not open the selected item")
clickSource.hitRow = clickedFolder
precondition(app.sendAction(controller.table.doubleAction!, to: controller, from: clickSource))
waitFor("double-click opens hit row, not previous selection") { !controller.busy && !controller.filtering && controller.path == original + "/exports" }
controller.navigate(original)
waitFor("return for keyboard open") { !controller.busy && !controller.filtering && controller.path == original }
controller.table.selectRowIndexes(IndexSet(integer: controller.visible.firstIndex(where: { $0.name == "child" })!), byExtendingSelection: false)
controller.table.openSelection?()
waitFor("keyboard open still uses selection") { !controller.busy && controller.path == original + "/child" }
controller.stopTransfers()
controller.disconnect()
print("PASS: controller recovery; idle detection, navigation replay, bounded read retry, no mutation replay, retry budget, cancel and server switch")
