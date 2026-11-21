import AppKit

final class TransferProgress: NSProgressIndicator {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class TransferWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var buttons: [String: NSButton] = [:]
    var items: [TransferItem] = [] { didSet { let selected = table.selectedRow; table.reloadData(); if items.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }; updateButtons() } }
    var action: ((UUID, String) -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "传输与正在编辑"; window.minSize = NSSize(width: 760, height: 300)
        super.init(window: window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        for (id, title, width) in [("name", "文件", 220.0), ("progress", "进度", 170.0), ("state", "状态", 440.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = CGFloat(width); table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30
        table.setAccessibilityLabel("上传、下载与自动同步任务")
        let buttons = NSStackView(); buttons.spacing = 6
        for (title, value) in [("本地副本", "local"), ("重试 / 续传", "retry"), ("重新上传", "restart"), ("保留两份", "copy"), ("覆盖远程…", "overwrite"), ("重新加载…", "reload"), ("停止任务", "pause")] {
            let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(value); button.bezelStyle = .rounded; button.toolTip = title + "（选中的任务）"; buttons.addArrangedSubview(button)
            self.buttons[value] = button
        }
        let help = NSTextField(wrappingLabelWithString: "拖出下载的文件不会自动回传；失败或取消后请重新拖出。双击打开的文本保存后自动同步，停止同步会保留本地副本。")
        help.textColor = .secondaryLabelColor; help.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [scroll, buttons, help]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        window.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)])
        window.center()
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        let item = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        for (action, button) in buttons {
            button.isEnabled = item != nil && (item?.isDownload != true || action == "local" || (action == "pause" && item?.state != "done" && item?.state != "stopped"))
        }
    }
    @objc private func performAction(_ sender: NSButton) {
        guard items.indices.contains(table.selectedRow), let value = sender.identifier?.rawValue else { return }
        let item = items[table.selectedRow]
        if value == "local" { NSWorkspace.shared.activateFileViewerSelecting([item.local]); return }
        if item.isDownload == true && value != "pause" { return }
        if value == "reload" && !item.editing { return }
        if value == "overwrite" && item.state != "conflict" { return }
        if ["overwrite", "reload"].contains(value), let window = window {
            let alert = NSAlert(); alert.messageText = value == "overwrite" ? "用本地副本覆盖远程文件？" : "重新加载远程版本？"
            alert.informativeText = item.remote + (value == "reload" ? "\n当前本地内容会保留为 backup 文件。" : "\n若远程再次变化，将再次提示冲突。")
            alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] result in if result == .alertFirstButtonReturn { self?.action?(item.id, value) } }
        } else { action?(item.id, value) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if tableColumn?.identifier.rawValue == "progress" {
            let bar = NSProgressIndicator(); bar.style = .bar; bar.controlSize = .small
            bar.minValue = 0; bar.maxValue = 100
            bar.isIndeterminate = item.phase != nil && item.percent == nil
            bar.doubleValue = Double(item.percent ?? 0)
            if bar.isIndeterminate { bar.startAnimation(nil) }
            bar.setAccessibilityLabel("传输进度")
            let label = NSTextField(labelWithString: item.percent.map { "\($0)%" } ?? "—")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let row = NSStackView(views: [bar, label]); row.spacing = 6; row.alignment = .centerY
            bar.widthAnchor.constraint(equalToConstant: 90).isActive = true
            row.toolTip = item.detail; return row
        }
        let text = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? (item.remote as NSString).lastPathComponent : item.detail)
        text.lineBreakMode = .byTruncatingMiddle; text.toolTip = "\(item.connection.label)\n\(item.remote)\n\(item.detail)\n\(item.local.path)"
        return text
    }
}
