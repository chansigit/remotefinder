import AppKit
import Darwin
import UniformTypeIdentifiers

private struct PromisedDownload {
    let connection: ConnectionProfile
    let remote: String
    let transfers: TransferManager
}

private final class FileTable: NSTableView {
    var openSelection: (() -> Void)?
    var renameSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { renameSelection?() }
        else if event.keyCode == 125 && event.modifierFlags.contains(.command) { openSelection?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { deselectAll(nil) }
        return super.menu(for: event)
    }
}

private final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class FileRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(calibratedRed: 0, green: 0.48, blue: 0.46, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class BrowserController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSFilePromiseProviderDelegate {
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "RemoteFinder.filePromises"; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let table = FileTable()
    private let pathBar = RemotePathBar()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "连接服务器，开始浏览远程文件")
    private let connectionLabel = NSTextField(labelWithString: "尚未连接")
    private let spinner = NSProgressIndicator()
    private let sidebar = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let folderTitle = NSTextField(labelWithString: "远程文件")
    private let folderSubtitle = NSTextField(labelWithString: "连接你的服务器，像本地一样浏览。")
    private let emptyIcon = NSImageView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var refreshButton: NSButton!
    private var stopButton: NSButton!
    private var hiddenButton: NSButton!
    private var bookmarkButton: NSButton!
    private var renameButton: NSButton!
    private var client: SFTPClient?
    private var profile: ConnectionProfile?
    private var transferWindow: TransferWindow?
    private var transferItems: [TransferItem] = []
    private var transferButton: NSButton!
    private let transferProgress = TransferProgress()
    private lazy var transfers: TransferManager = {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoteFinder/Transfers")
        let manager = TransferManager(root: root) { connection, interactive in
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let helper = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/askpass")
            return try SFTPClient(profile: connection, askpass: helper.path, interactive: interactive)
        }
        manager.onChange = { [weak self] items in
            guard let self = self else { return }
            let changed = items.filter { item in item.baseline != nil && item.baseline != self.transferItems.first(where: { $0.id == item.id })?.baseline }
            if !changed.isEmpty { self.cache.removeAll() }
            self.transferItems = items; self.transferWindow?.items = items
            if !self.busy, self.client?.isUsable == true, let current = self.profile,
               changed.contains(where: { $0.connection.sameServer(as: current) && ($0.remote as NSString).deletingLastPathComponent == self.path }) {
                let directory = self.path
                self.run("正在刷新上传结果…", retryRead: true) { try $0.list(directory) } completion: { [weak self] contents in
                    guard let self = self, self.path == directory else { return }
                    self.entries = contents; self.cache.insert(contents, at: directory); self.applyFilter()
                }
            }
            let pending = items.filter { !["done", "stopped"].contains($0.state) }.count
            let active = items.first(where: { $0.phase != nil && $0.state == "queued" }) ?? items.first(where: { $0.state == "preparing" })
            self.transferProgress.isHidden = active == nil
            self.transferProgress.isIndeterminate = active?.percent == nil
            self.transferProgress.doubleValue = Double(active?.percent ?? 0)
            if active != nil && active?.percent == nil { self.transferProgress.startAnimation(nil) }
            else { self.transferProgress.stopAnimation(nil) }
            let issues = items.filter { ["error", "conflict", "paused"].contains($0.state) }.count
            let queuedCount = items.filter { ["queued", "preparing"].contains($0.state) }.count
            self.transferButton.title = active.map { $0.progressText + " · \(queuedCount) 项" } ?? (issues > 0 ? "传输 · \(issues) 项待处理" : "传输与编辑（\(pending)）")
            self.transferButton.toolTip = active.map { ($0.remote as NSString).lastPathComponent + "\n" + $0.detail + "\n点击查看传输面板" } ?? "查看传输、续传和本地编辑同步"
            self.transferProgress.toolTip = self.transferButton.toolTip
        }
        return manager
    }()

    private var path = ""
    private var home = ""
    private var entries: [RemoteEntry] = []
    private var visible: [RemoteEntry] = []
    private var backHistory: [String] = []
    private var forwardHistory: [String] = []
    private var cache = DirectoryCache()
    private let listingWorker = ListingWorker()
    private var filtering = false
    private var icons: [String: NSImage] = [:]
    private var busy = false
    private var showHidden = false
    private var generation = UUID()
    private var connectionMonitor: Timer?
    private var reconnectWork: DispatchWorkItem?
    private let worker = DispatchQueue(label: "RemoteFinder.sftp", qos: .userInitiated)
    private var profiles: [ConnectionProfile] = []
    private var savedLocations = SavedLocation.load()
    private var savedConnections = SavedLocation.load(key: "savedConnections")
    private let teal = NSColor(calibratedRed: 0, green: 0.48, blue: 0.46, alpha: 1)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RemoteFinder"
        window.minSize = NSSize(width: 960, height: 520)
        window.titlebarAppearsTransparent = false
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.closeButton)?.toolTip = "关闭 RemoteFinder"
        window.standardWindowButton(.miniaturizeButton)?.toolTip = "最小化窗口"
        window.standardWindowButton(.zoomButton)?.toolTip = "缩放窗口 / 进入全屏"
        super.init(window: window)
        if let data = UserDefaults.standard.data(forKey: "connections"), let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) { profiles = saved }
        buildInterface()
        _ = transfers
        window.center()
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: size); view.textColor = color
        return view
    }
    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let view = NSButton(title: title, target: self, action: action)
        view.bezelStyle = .texturedRounded
        view.contentTintColor = teal
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        view.imagePosition = .imageOnly; view.toolTip = title
        view.setAccessibilityLabel(title)
        view.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return view
    }
    private func glass(_ material: NSVisualEffectView.Material, radius: CGFloat = 0) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .active
        view.wantsLayer = true; view.layer?.cornerRadius = radius; view.layer?.masksToBounds = true
        return view
    }
    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let backdrop = glass(.underWindowBackground)
        root.addSubview(backdrop); backdrop.translatesAutoresizingMaskIntoConstraints = false
        let rail = glass(.sidebar)
        root.addSubview(rail); rail.translatesAutoresizingMaskIntoConstraints = false
        let tint = NSView(); tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.5, blue: 0.5, alpha: 0.13).cgColor
        rail.addSubview(tint); tint.translatesAutoresizingMaskIntoConstraints = false
        let sideScroll = NSScrollView(); sideScroll.contentView = TopAlignedClipView()
        sideScroll.drawsBackground = false; sideScroll.contentView.drawsBackground = false
        sideScroll.hasVerticalScroller = true; sideScroll.autohidesScrollers = true
        rail.addSubview(sideScroll); sideScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        sideScroll.documentView = sidebar; sidebar.translatesAutoresizingMaskIntoConstraints = false
        let footnote = label("SSH 加密连接 · 本地打开", size: 11)
        rail.addSubview(footnote); footnote.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        let chrome = glass(.headerView, radius: 8)
        content.addSubview(chrome); chrome.translatesAutoresizingMaskIntoConstraints = false
        backButton = button("后退：返回上一个目录", "chevron.left", #selector(goBack))
        forwardButton = button("前进：打开下一个目录", "chevron.right", #selector(goForward))
        upButton = button("上一级：打开父目录", "arrow.up", #selector(goUp))
        refreshButton = button("刷新当前目录（⌘R）", "arrow.clockwise", #selector(refresh))
        stopButton = button("断开目录浏览连接（后台传输请在传输面板停止）", "xmark.circle", #selector(disconnect))
        hiddenButton = button("显示隐藏文件（⇧⌘.）", "eye.slash", #selector(toggleHidden))
        bookmarkButton = button("收藏当前目录（⌘D）", "star", #selector(saveCurrentLocation))
        renameButton = button("重命名选中的远程文件或文件夹（Return）", "square.and.pencil", #selector(renameSelected))
        let connect = NSButton(title: "连接", target: self, action: #selector(showConnect))
        connect.bezelStyle = .rounded; connect.toolTip = "连接 SSH / SFTP 服务器（⌘K）"
        connect.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); connect.imagePosition = .imageLeading
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.placeholderString = "筛选当前目录"; search.delegate = self
        search.setAccessibilityLabel("筛选当前文件夹"); search.toolTip = "按名称筛选当前目录，不搜索子目录"
        search.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let toolbar = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, hiddenButton, bookmarkButton, renameButton, spacer, search, stopButton, connect])
        toolbar.spacing = 4; toolbar.orientation = .horizontal
        chrome.addSubview(toolbar); toolbar.translatesAutoresizingMaskIntoConstraints = false

        folderTitle.font = .systemFont(ofSize: 20, weight: .semibold); folderTitle.lineBreakMode = .byTruncatingMiddle
        folderSubtitle.font = .systemFont(ofSize: 12); folderSubtitle.textColor = .secondaryLabelColor
        folderSubtitle.lineBreakMode = .byTruncatingMiddle
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        folderIcon.contentTintColor = teal
        let heading = NSStackView(views: [folderIcon, folderTitle]); heading.spacing = 8
        content.addSubview(heading); heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(folderSubtitle); folderSubtitle.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        content.addSubview(pathBar); pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onNavigate = { [weak self] destination in self?.navigate(destination) }

        let fileGlass = glass(.contentBackground, radius: 8)
        content.addSubview(fileGlass); fileGlass.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder; scroll.documentView = table
        fileGlass.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in [("name", "名称", 420.0), ("size", "大小", 110.0), ("date", "修改日期", 195.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = CGFloat(width); column.minWidth = id == "name" ? 160 : 80
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            column.headerToolTip = "按“\(title)”排序，再次点击切换升序 / 降序"
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 26; table.intercellSpacing = NSSize(width: 8, height: 2)
        table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = false; table.style = .inset
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openClicked(_:))
        table.openSelection = { [weak self] in self?.openSelected() }
        table.renameSelection = { [weak self] in self?.renameSelected() }
        let menu = NSMenu()
        for (title, action) in [("打开", #selector(openSelected)), ("重命名…", #selector(renameSelected))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        table.registerForDraggedTypes([.fileURL])
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.toolTip = "将文件或文件夹拖到 Finder 或桌面下载（包含子目录）；将本地文件拖入这里上传。"
        table.menu = menu
        table.setAccessibilityLabel("远程文件")
        emptyLabel.alignment = .center; emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize: 14)
        emptyIcon.image = Bundle.main.image(forResource: "RemoteFinder")
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        fileGlass.addSubview(emptyIcon); emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        fileGlass.addSubview(emptyLabel); emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        transferButton = NSButton(title: "传输与编辑（0）", target: self, action: #selector(showTransfers))
        transferButton.bezelStyle = .recessed; transferButton.toolTip = "查看上传进度、冲突、断点续传和本地编辑同步"
        transferProgress.style = .bar; transferProgress.controlSize = .small
        transferProgress.minValue = 0; transferProgress.maxValue = 100; transferProgress.isHidden = true
        transferProgress.setAccessibilityLabel("后台传输进度，点击查看传输面板")
        transferProgress.onClick = { [weak self] in self?.showTransfers() }
        transferProgress.widthAnchor.constraint(equalToConstant: 96).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spinner, status, transferProgress, transferButton]); footer.orientation = .horizontal; footer.spacing = 8
        content.addSubview(footer); footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor), backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor), rail.topAnchor.constraint(equalTo: root.topAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor), rail.widthAnchor.constraint(equalToConstant: 220),
            tint.leadingAnchor.constraint(equalTo: rail.leadingAnchor), tint.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            tint.topAnchor.constraint(equalTo: rail.topAnchor), tint.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: rail.leadingAnchor), sideScroll.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo: rail.topAnchor), sideScroll.bottomAnchor.constraint(equalTo: footnote.topAnchor, constant: -10),
            sidebar.leadingAnchor.constraint(equalTo: sideScroll.contentView.leadingAnchor), sidebar.trailingAnchor.constraint(equalTo: sideScroll.contentView.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sideScroll.contentView.topAnchor),
            footnote.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 16), footnote.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: rail.trailingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), chrome.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            chrome.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), chrome.heightAnchor.constraint(equalToConstant: 40),
            toolbar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 8), toolbar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -8),
            toolbar.centerYAnchor.constraint(equalTo: chrome.centerYAnchor), toolbar.heightAnchor.constraint(equalToConstant: 30),
            heading.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 4), heading.trailingAnchor.constraint(lessThanOrEqualTo: chrome.trailingAnchor),
            heading.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: 12),
            folderSubtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 32), folderSubtitle.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            folderSubtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            pathBar.topAnchor.constraint(equalTo: folderSubtitle.bottomAnchor, constant: 10), pathBar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor), pathBar.heightAnchor.constraint(equalToConstant: 32),
            fileGlass.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 8), fileGlass.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            fileGlass.trailingAnchor.constraint(equalTo: chrome.trailingAnchor), fileGlass.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: fileGlass.topAnchor), scroll.leadingAnchor.constraint(equalTo: fileGlass.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fileGlass.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: fileGlass.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 4), footer.trailingAnchor.constraint(lessThanOrEqualTo: chrome.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: 35),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
            emptyIcon.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyIcon.bottomAnchor.constraint(equalTo: emptyLabel.topAnchor, constant: -24),
            emptyIcon.widthAnchor.constraint(equalToConstant: 88), emptyIcon.heightAnchor.constraint(equalToConstant: 88)
        ])
        rebuildSidebar()
        applyFilter()
    }

    private func rebuildSidebar() {
        sidebar.arrangedSubviews.forEach { sidebar.removeArrangedSubview($0); $0.removeFromSuperview() }
        let logo = NSImageView(image: Bundle.main.image(forResource: "RemoteFinder") ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 38).isActive = true; logo.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let brand = label("RemoteFinder", size: 16, color: .labelColor); brand.font = .systemFont(ofSize: 16, weight: .semibold)
        let branding = NSStackView(views: [logo, brand]); branding.spacing = 6
        sidebar.addArrangedSubview(branding)
        sidebar.setCustomSpacing(16, after: sidebar.arrangedSubviews.last!)
        sidebar.addArrangedSubview(label("当前位置", size: 11))
        connectionLabel.font = .systemFont(ofSize: 13, weight: .medium); connectionLabel.lineBreakMode = .byTruncatingMiddle
        connectionLabel.stringValue = profile?.label ?? "尚未连接"
        if connectionLabel.constraints.isEmpty { connectionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 188).isActive = true }
        connectionLabel.toolTip = profile?.label ?? "连接服务器后显示当前连接"
        sidebar.addArrangedSubview(connectionLabel)
        let homeButton = NSButton(title: "个人目录", target: self, action: #selector(goHome))
        homeButton.bezelStyle = .recessed; homeButton.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        homeButton.imagePosition = .imageLeading; homeButton.isEnabled = client != nil
        homeButton.toolTip = "打开当前服务器的个人目录"
        sidebar.addArrangedSubview(homeButton)
        sidebar.setCustomSpacing(16, after: homeButton)
        sidebar.addArrangedSubview(label("收藏目录", size: 11))
        if savedLocations.isEmpty { sidebar.addArrangedSubview(label("点击工具栏 ☆ 保存当前目录", size: 11)) }
        for (index, location) in savedLocations.enumerated() {
            let item = NSButton(title: location.name, target: self, action: #selector(openSavedLocation(_:)))
            item.tag = index; item.bezelStyle = .recessed; item.alignment = .left; item.lineBreakMode = .byTruncatingTail
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); item.imagePosition = .imageLeading
            item.contentTintColor = teal
            item.toolTip = "打开收藏：\(location.name)\n\(location.connection.label)\n\(location.connection.path)"
            let more = button("管理收藏：重命名或移除“\(location.name)”", "ellipsis", #selector(manageSavedLocation(_:)))
            more.tag = index; more.isBordered = false
            let row = NSStackView(views: [item, more]); row.spacing = 2
            sidebar.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 188).isActive = true
            item.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sidebar.setCustomSpacing(16, after: sidebar.arrangedSubviews.last!)
        sidebar.addArrangedSubview(label("常用连接", size: 11))
        for (index, connection) in savedConnections.enumerated() {
            let item = NSButton(title: connection.name, target: self, action: #selector(openSavedConnection(_:)))
            item.tag = index; item.bezelStyle = .recessed; item.alignment = .left; item.lineBreakMode = .byTruncatingTail
            item.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil); item.imagePosition = .imageLeading
            item.contentTintColor = teal; item.toolTip = "连接 \(connection.name)\n\(connection.connection.label)\n\(connection.connection.path)"
            let more = button("编辑或移除连接“\(connection.name)”", "ellipsis", #selector(manageSavedConnection(_:)))
            more.tag = index; more.isBordered = false
            let row = NSStackView(views: [item, more]); row.spacing = 2
            sidebar.addArrangedSubview(row); row.widthAnchor.constraint(equalToConstant: 188).isActive = true
            item.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        if savedConnections.isEmpty { sidebar.addArrangedSubview(label("新建连接，或收藏最近连接", size: 11)) }
        sidebar.setCustomSpacing(16, after: sidebar.arrangedSubviews.last!)
        sidebar.addArrangedSubview(label("最近连接", size: 11))
        if profiles.isEmpty { sidebar.addArrangedSubview(label("成功连接后会保存在这里", size: 11)) }
        for (index, connection) in profiles.enumerated() {
            let item = NSButton(title: connection.label, target: self, action: #selector(connectRecent(_:)))
            item.tag = index; item.bezelStyle = .recessed; item.alignment = .left
            item.lineBreakMode = .byTruncatingMiddle; item.toolTip = "连接 \(connection.label) 并打开\n\(connection.path)"
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil); item.imagePosition = .imageLeading
            let save = button("保存此最近连接为常用连接", "star", #selector(saveRecentConnection(_:)))
            save.tag = index; save.isBordered = false
            let row = NSStackView(views: [item, save]); row.spacing = 2
            sidebar.addArrangedSubview(row); row.widthAnchor.constraint(equalToConstant: 188).isActive = true
            item.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let add = NSButton(title: "+  新建连接…", target: self, action: #selector(showConnect))
        add.bezelStyle = .recessed; add.toolTip = "添加 SSH / SFTP 连接（⌘K）"; sidebar.addArrangedSubview(add)
        sidebar.setCustomSpacing(16, after: add)
        let help = NSTextField(wrappingLabelWithString: "⌘D  收藏当前目录\nReturn  重命名选中项目\n⌘O  打开选中文件\n⌘L  输入路径\n⇧⌘.  显示隐藏文件")
        help.font = .systemFont(ofSize: 11); help.textColor = .tertiaryLabelColor
        sidebar.addArrangedSubview(help)
    }

    private func storeConnection(_ connection: ConnectionProfile, name: String, id: UUID? = nil) {
        if let index = savedConnections.firstIndex(where: { $0.id == id || (id == nil && $0.connection == connection) }) {
            savedConnections[index].name = name; savedConnections[index].connection = connection
        } else { savedConnections.append(SavedLocation(name: name, connection: connection)) }
        SavedLocation.save(savedConnections, key: "savedConnections"); rebuildSidebar()
    }

    @objc private func saveRecentConnection(_ sender: NSButton) {
        let connection = profiles[sender.tag]
        askName(title: "保存为常用连接", detail: "\(connection.label)\n\(connection.path)\n保存连接信息，不保存密码。", value: connection.label, action: "保存连接") { [weak self] name in
            self?.storeConnection(connection, name: name)
        }
    }

    @objc private func openSavedConnection(_ sender: NSButton) { connect(savedConnections[sender.tag].connection) }

    @objc private func manageSavedConnection(_ sender: NSButton) {
        let id = savedConnections[sender.tag].id.uuidString
        let menu = NSMenu()
        for (title, action) in [("编辑连接 / 名称…", #selector(editSavedConnection(_:))), ("忘记已保存密码…", #selector(forgetSavedPassword(_:))), ("移除常用连接", #selector(removeSavedConnection(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = id
        }
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    }

    @objc private func editSavedConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let item = savedConnections.first(where: { $0.id.uuidString == id }) else { return }
        showConnectionForm(existing: item)
    }

    @objc func forgetCurrentPassword() {
        guard let connection = profile ?? profiles.first else { return }
        forgetPassword(connection)
    }

    @objc private func forgetSavedPassword(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let item = savedConnections.first(where: { $0.id.uuidString == id }) else { return }
        forgetPassword(item.connection)
    }

    private func forgetPassword(_ connection: ConnectionProfile) {
        guard let window = window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "忘记已保存密码？"
        alert.informativeText = "\(connection.label)\n删除此连接保存在 macOS 钥匙串中的密码，下次需要时重新输入。服务器密码和当前连接不会改变。"
        alert.addButton(withTitle: "忘记密码").toolTip = "删除此连接的本地钥匙串密码"
        alert.addButton(withTitle: "取消").toolTip = "保留已保存密码"
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            do {
                try SSHPasswordStore(profile: connection).forget()
                self?.status.stringValue = "已忘记密码 · 下次需要时重新输入"
            } catch { self?.showError(error.localizedDescription) }
        }
    }

    @objc private func removeSavedConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        savedConnections.removeAll { $0.id.uuidString == id }
        SavedLocation.save(savedConnections, key: "savedConnections"); rebuildSidebar()
    }

    @objc func saveCurrentLocation() {
        guard !busy, var connection = profile, !path.isEmpty else { return }
        connection.path = path
        let existing = savedLocations.first { $0.connection == connection }
        let suggested = existing?.name ?? (path == "/" ? "/" : (path as NSString).lastPathComponent)
        askName(title: existing == nil ? "收藏当前目录" : "修改收藏名称", detail: "\(connection.label)\n\(path)\n只保存目录位置，不下载文件。", value: suggested, action: "保存收藏") { [weak self] name in
            guard let self = self else { return }
            if let index = self.savedLocations.firstIndex(where: { $0.connection == connection }) {
                self.savedLocations[index].name = name
            } else { self.savedLocations.append(SavedLocation(name: name, connection: connection)) }
            self.persistLocations()
            self.status.stringValue = "已收藏“\(name)” · 可从侧边栏随时打开"
        }
    }

    private func persistLocations() {
        SavedLocation.save(savedLocations); rebuildSidebar(); updateControls()
    }

    @objc private func openSavedLocation(_ sender: NSButton) {
        let connection = savedLocations[sender.tag].connection
        if let current = profile, current.sameServer(as: connection), client?.isUsable == true, !path.isEmpty {
            guard !busy else { return }
            navigate(connection.path)
        } else { connect(connection) }
    }

    @objc private func manageSavedLocation(_ sender: NSButton) {
        let location = savedLocations[sender.tag]
        let menu = NSMenu()
        for (title, action) in [("重命名收藏…", #selector(renameSavedLocation(_:))), ("移除收藏", #selector(removeSavedLocation(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = location.id.uuidString
        }
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    }

    @objc private func renameSavedLocation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let location = savedLocations.first(where: { $0.id.uuidString == id }) else { return }
        askName(title: "重命名收藏", detail: "仅修改侧边栏名称，远程目录不会改变。", value: location.name, action: "保存名称") { [weak self] name in
            guard let self = self, let index = self.savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
            self.savedLocations[index].name = name; self.persistLocations()
        }
    }

    @objc private func removeSavedLocation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        savedLocations.removeAll { $0.id.uuidString == id }; persistLocations()
        status.stringValue = "已移除收藏 · 远程目录未改变"
    }

    private func askName(title: String, detail: String, value: String, action: String, completion: @escaping (String) -> Void) {
        guard let window = window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action).toolTip = action
        alert.addButton(withTitle: "取消").toolTip = "取消，不保存更改"
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 420, height: 26)
        field.setAccessibilityLabel("名称"); alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self?.showError("名称不能为空。"); return }
            completion(name)
        }
    }

    @objc func renameSelected() {
        guard !busy, !filtering, client?.isUsable == true, let current = profile, visible.indices.contains(table.selectedRow) else { return }
        let entry = visible[table.selectedRow]; let directory = path; let token = generation
        askName(title: "重命名远程项目", detail: "\(entry.name)\n会修改服务器上的名称；不会覆盖已有的同名项目。", value: entry.name, action: "重命名") { [weak self] name in
            guard let self = self, self.generation == token, self.path == directory, !self.busy, name != entry.name else { return }
            self.run("正在重命名…", mutation: true) { session in
                try session.rename(in: directory, from: entry.name, to: name)
            } completion: { [weak self] _ in
                guard let self = self else { return }
                let oldPath = self.childPath(entry.name); let newPath = self.childPath(name)
                for index in self.savedLocations.indices where self.savedLocations[index].connection.sameServer(as: current) {
                    self.savedLocations[index].connection.path = replacingRemotePath(self.savedLocations[index].connection.path, from: oldPath, to: newPath)
                }
                for index in self.profiles.indices where self.profiles[index].sameServer(as: current) {
                    self.profiles[index].path = replacingRemotePath(self.profiles[index].path, from: oldPath, to: newPath)
                }
                for index in self.savedConnections.indices where self.savedConnections[index].connection.sameServer(as: current) {
                    self.savedConnections[index].connection.path = replacingRemotePath(self.savedConnections[index].connection.path, from: oldPath, to: newPath)
                }
                SavedLocation.save(self.savedConnections, key: "savedConnections")
                self.backHistory = self.backHistory.map { replacingRemotePath($0, from: oldPath, to: newPath) }
                self.forwardHistory = self.forwardHistory.map { replacingRemotePath($0, from: oldPath, to: newPath) }
                self.home = replacingRemotePath(self.home, from: oldPath, to: newPath)
                self.persistLocations(); self.saveConnection()
                self.cache.removeAll(); self.entries.removeAll(); self.applyFilter()
                self.run("已重命名，正在刷新目录…", retryRead: true) { session in try session.list(directory) } completion: { [weak self] entries in
                    guard let self = self else { return }
                    self.display(entries, at: directory, selecting: name)
                    self.status.stringValue = "已重命名为“\(name)”"
                }
            }
        }
    }

    @objc func showConnect() { showConnectionForm() }

    private func showConnectionForm(existing: SavedLocation? = nil) {
        guard let window = window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "新建 SSH / SFTP 连接" : "编辑连接"
        alert.informativeText = "支持 ~/.ssh/config 别名、密钥和 SSH agent。输入密码时可选择保存到 macOS 钥匙串；验证码不保存。"
        alert.addButton(withTitle: "保存并连接").toolTip = "保存连接配置并连接；可在认证时选择记住密码"
        alert.addButton(withTitle: "仅保存").toolTip = "保存到常用连接，暂不连接服务器"
        alert.addButton(withTitle: "取消").toolTip = "关闭连接表单"
        let previous = existing?.connection
        let name = NSTextField(string: existing?.name ?? ""); name.placeholderString = "例如：实验室服务器"
        let host = NSTextField(string: previous?.host ?? ""); host.placeholderString = "主机名或 SSH 别名"
        let user = NSTextField(string: previous?.user ?? ""); user.placeholderString = "留空使用 SSH 配置"
        let port = NSTextField(string: previous?.port ?? ""); port.placeholderString = "留空使用 SSH 配置 / 22"
        let start = NSTextField(string: previous?.path ?? "."); start.placeholderString = "默认个人目录"
        let grid = NSGridView(views: [[label("名称"), name], [label("服务器"), host], [label("用户名"), user], [label("端口"), port], [label("起始目录"), start]])
        grid.rowSpacing = 12; grid.columnSpacing = 14
        grid.frame = NSRect(x: 0, y: 0, width: 430, height: 180)
        grid.column(at: 0).width = 65
        for (field, label) in [(name, "连接名称"), (host, "服务器"), (user, "用户名"), (port, "端口"), (start, "起始目录")] { field.setAccessibilityLabel(label) }
        name.nextKeyView = host; host.nextKeyView = user; user.nextKeyView = port; port.nextKeyView = start
        alert.accessoryView = grid; alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn || result == .alertSecondButtonReturn else { return }
            let trim = CharacterSet.whitespacesAndNewlines
            let connection = ConnectionProfile(host: host.stringValue.trimmingCharacters(in: trim), user: user.stringValue.trimmingCharacters(in: trim), port: port.stringValue.trimmingCharacters(in: trim), path: start.stringValue.isEmpty ? "." : start.stringValue)
            do { _ = try connection.arguments() } catch { self?.showError(error.localizedDescription); return }
            let displayName = name.stringValue.trimmingCharacters(in: trim)
            self?.storeConnection(connection, name: displayName.isEmpty ? connection.label : displayName, id: existing?.id)
            if result == .alertFirstButtonReturn { self?.connect(connection) }
        }
    }

    @objc private func connectRecent(_ sender: NSButton) { connect(profiles[sender.tag]) }

    private func connect(_ connection: ConnectionProfile) {
        let session: SFTPClient
        do {
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let helper = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/askpass")
            session = try SFTPClient(profile: connection, askpass: helper.path)
        } catch { showError(error.localizedDescription); return }
        disconnect()
        client = session; profile = connection
        rebuildSidebar()
        run("正在连接 \(connection.label)…") { session -> (String, String, [RemoteEntry]) in
            try session.start()
            let home = try session.realpath(".")
            let initial = connection.path == "~" ? home : connection.path.hasPrefix("~/") ? home + String(connection.path.dropFirst()) : connection.path
            let resolved = try session.realpath(initial)
            return (home, resolved, try session.list(resolved))
        } completion: { [weak self] result in
            guard let self = self else { return }
            self.startConnectionMonitor()
            self.home = result.0
            self.cache.insert(result.2, at: result.1)
            self.display(result.2, at: result.1)
            self.saveConnection()
        }
    }

    private func startConnectionMonitor() {
        connectionMonitor?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, !self.busy, !self.path.isEmpty,
                  let session = self.client, !session.isUsable else { return }
            self.recoverConnection()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        connectionMonitor = timer
    }

    // Only reads can be replayed. A lost rename response leaves its outcome unknown.
    private func run<T>(_ message: String, retryRead: Bool = false, mutation: Bool = false, recoverOnFailure: Bool = true,
                        operation: @escaping (SFTPClient) throws -> T, completion: @escaping (T) -> Void) {
        guard let session = client, !busy else { return }
        let token = generation
        busy = true; status.stringValue = message; updateControls()
        if visible.isEmpty { emptyLabel.stringValue = message }
        worker.async {
            do {
                let result = try operation(session)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.busy = false; completion(result); self.updateControls()
                }
            } catch {
                let detail = session.diagnosticMessage(error)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.busy = false
                    if !session.isUsable && !self.path.isEmpty {
                        guard recoverOnFailure else {
                            self.connectionMonitor?.invalidate(); self.connectionMonitor = nil
                            self.cache.removeAll()
                            self.status.stringValue = "网络仍不稳定 · 点击刷新重新连接"
                            self.updateControls(); self.showError(detail); return
                        }
                        self.recoverConnection(resume: retryRead ? { [weak self] in
                            self?.run(message, recoverOnFailure: false, operation: operation, completion: completion)
                        } : nil)
                        if mutation { self.showError("重命名结果未确认，恢复连接后请检查目录，避免重复操作。\n\n" + detail) }
                        else if !retryRead { self.showError(detail) }
                        return
                    }
                    if self.path.isEmpty { self.disconnect() }
                    self.status.stringValue = self.client == nil ? "连接已断开 · 请从侧边栏重新连接" : "操作失败 · 可以重试"
                    self.updateControls(); self.showError(detail)
                }
            }
        }
    }

    private func recoverConnection(attempt: Int = 0, resume: (() -> Void)? = nil) {
        guard let connection = profile, !path.isEmpty else { return }
        connectionMonitor?.invalidate(); connectionMonitor = nil
        reconnectWork?.cancel(); client?.cancel(); cache.removeAll()
        let delays: [TimeInterval] = [1, 2, 4, 8, 16]
        guard attempt < delays.count else {
            busy = false
            status.stringValue = "自动重连未成功 · 点击刷新或最近连接，重新认证"
            status.toolTip = "网络恢复后可点击刷新（⌘R）。已保存密码无法使用、或服务器需要验证码 / 私钥口令时，请手动完成认证。"
            updateControls(); return
        }
        let token = generation
        let directory = path
        busy = true
        status.stringValue = "连接中断 · \(Int(delays[attempt])) 秒后自动重连（\(attempt + 1)/\(delays.count)）"
        updateControls()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token else { return }
            let session: SFTPClient
            do {
                let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                let helper = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/askpass")
                session = try SFTPClient(profile: connection, askpass: helper.path, interactive: false)
            } catch {
                self.busy = false; self.status.stringValue = error.localizedDescription; self.updateControls(); return
            }
            self.client = session
            self.status.stringValue = "正在自动重连（\(attempt + 1)/\(delays.count)）…"
            self.worker.async {
                do {
                    try session.start()
                    let home = try session.realpath(".")
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.generation == token else { return }
                        self.busy = false; self.home = home; self.status.toolTip = nil
                        self.startConnectionMonitor(); self.updateControls()
                        if let resume = resume { resume() }
                        else {
                            self.run("连接已恢复，正在刷新目录…", recoverOnFailure: false) { try $0.list(directory) } completion: { [weak self] contents in
                                guard let self = self else { return }
                                self.entries = contents; self.cache.insert(contents, at: directory)
                                self.applyFilter()
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.generation == token else { return }
                        // A failed saved-password attempt may be a bad password or MFA; avoid account lockouts.
                        if session.usedSavedPassword {
                            self.busy = false
                            self.status.stringValue = "已保存密码未能完成认证 · 点击刷新手动连接"
                            self.updateControls()
                        } else { self.recoverConnection(attempt: attempt + 1, resume: resume) }
                    }
                }
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    private func saveConnection() {
        guard var connection = profile else { return }
        connection.path = path
        let updated = [connection] + profiles.filter { !$0.sameServer(as: connection) }.prefix(9)
        guard updated != profiles else { return }
        profiles = updated
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "connections") }
        rebuildSidebar()
    }

    private func navigate(_ destination: String, history: Int = 0, force: Bool = false) {
        guard client != nil, !busy else { return }
        let target = destination == "~" ? home : destination.hasPrefix("~/") ? home + String(destination.dropFirst()) : destination.hasPrefix("/") ? destination : childPath(destination)
        func commit(_ resolved: String, _ contents: [RemoteEntry]) {
            if history == -1 { _ = backHistory.popLast(); forwardHistory.append(path) }
            else if history == 1 { _ = forwardHistory.popLast(); backHistory.append(path) }
            else if resolved != path && !path.isEmpty { backHistory.append(path); forwardHistory.removeAll() }
            if backHistory.count > 200 { backHistory.removeFirst(backHistory.count - 200) }
            if forwardHistory.count > 200 { forwardHistory.removeFirst(forwardHistory.count - 200) }
            display(contents, at: resolved); saveConnection()
        }
        if !force, let cached = cache.get(target) {
            commit(target, cached); updateControls(); return
        }
        run("正在读取文件夹…", retryRead: true) { session -> (String, [RemoteEntry]) in
            let resolved = try session.realpath(target)
            return (resolved, try session.list(resolved))
        } completion: { result in
            self.cache.insert(result.1, at: result.0)
            commit(result.0, result.1)
        }
    }

    private func childPath(_ name: String) -> String { (path == "/" ? "/" : path + "/") + name }
    private func display(_ contents: [RemoteEntry], at resolved: String, selecting name: String? = nil) {
        if path != resolved { table.deselectAll(nil); visible.removeAll(); table.reloadData() }
        path = resolved; profile?.path = resolved; entries = contents; pathBar.setPath(resolved)
        folderTitle.stringValue = resolved == "/" ? "/" : (resolved as NSString).lastPathComponent
        folderSubtitle.stringValue = profile?.label ?? ""
        window?.title = "\((resolved as NSString).lastPathComponent.isEmpty ? "/" : (resolved as NSString).lastPathComponent) — RemoteFinder"
        search.stringValue = ""; applyFilter(selecting: name)
    }
    private func applyFilter(delay: TimeInterval = 0, selecting name: String? = nil) {
        let selected = name ?? (visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].name : nil)
        listingWorker.cancel()
        guard !entries.isEmpty else { filtering = false; showListing([], selecting: nil); return }
        filtering = true; updateControls()
        if !busy && client?.isUsable == true { status.stringValue = "正在筛选和排序…" }
        let descriptor = table.sortDescriptors.first
        listingWorker.submit(entries, query: search.stringValue, showHidden: showHidden,
                             key: descriptor?.key ?? "name", ascending: descriptor?.ascending ?? true, delay: delay) { [weak self] result in
            guard let self = self else { return }
            self.filtering = false; self.showListing(result, selecting: selected)
        }
    }
    private func showListing(_ contents: [RemoteEntry], selecting name: String?) {
        table.deselectAll(nil)
        visible = contents; table.reloadData()
        if let name = name, let row = visible.firstIndex(where: { $0.name == name }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        emptyLabel.isHidden = !visible.isEmpty
        emptyIcon.isHidden = !visible.isEmpty
        emptyLabel.stringValue = client == nil ? "你的远程文件，就在这里。\n\n点击“连接服务器”或按 ⌘K\n双击文件夹浏览，双击文件用本地应用打开。" : busy ? "正在读取…" : "当前文件夹没有可显示的文件"
        if !busy && client?.isUsable == true { status.stringValue = "\(visible.count) 项 · 双击打开 · UTF-8 文本保存后自动同步" }
        updateControls()
    }
    private func updateControls() {
        let ready = client?.isUsable == true && !busy && !path.isEmpty
        backButton.isEnabled = ready && !backHistory.isEmpty
        forwardButton.isEnabled = ready && !forwardHistory.isEmpty
        upButton.isEnabled = ready && path != "/"
        refreshButton.isEnabled = profile != nil && !busy; pathBar.isEnabled = ready
        renameButton.isEnabled = ready && !filtering && visible.indices.contains(table.selectedRow)
        bookmarkButton.isEnabled = ready
        let saved = profile.map { current in savedLocations.contains { $0.connection.sameServer(as: current) && $0.connection.path == path } } ?? false
        bookmarkButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star", accessibilityDescription: nil)
        bookmarkButton.contentTintColor = teal
        bookmarkButton.toolTip = saved ? "当前目录已收藏，点击修改收藏名称（⌘D）" : "收藏当前目录（⌘D）"
        stopButton.isEnabled = client != nil
        if busy || filtering { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc func disconnect() {
        connectionMonitor?.invalidate(); connectionMonitor = nil
        reconnectWork?.cancel(); reconnectWork = nil; status.toolTip = nil
        generation = UUID(); client?.cancel(); client = nil; profile = nil; busy = false
        path = ""; home = ""; entries.removeAll(); cache.removeAll(); backHistory.removeAll(); forwardHistory.removeAll()
        pathBar.setPath(""); search.stringValue = ""
        window?.title = "RemoteFinder"; status.stringValue = "未连接 · ⌘K 连接服务器"
        folderTitle.stringValue = "远程文件"; folderSubtitle.stringValue = "连接你的服务器，像本地一样浏览。"
        rebuildSidebar(); applyFilter(); updateControls()
    }
    @objc func refresh() {
        guard !busy else { return }
        if client?.isUsable != true, let connection = profile { connect(connection) }
        else { navigate(path, force: true) }
    }
    @objc func focusPath() { pathBar.beginEditing() }
    @objc private func goBack() { if let target = backHistory.last { navigate(target, history: -1) } }
    @objc private func goForward() { if let target = forwardHistory.last { navigate(target, history: 1) } }
    @objc private func goUp() { navigate((path as NSString).deletingLastPathComponent) }
    @objc private func goHome() { navigate(home) }
    @objc func toggleHidden() {
        showHidden.toggle(); hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: "显示隐藏文件")
        hiddenButton.toolTip = showHidden ? "隐藏以 . 开头的文件（⇧⌘.）" : "显示隐藏文件（⇧⌘.）"
        applyFilter()
    }

    @objc func showTransfers() {
        if transferWindow == nil {
            let panel = TransferWindow(); panel.items = transferItems
            panel.action = { [weak self] id, action in self?.transfers.action(id, action) }
            transferWindow = panel
        }
        transferWindow?.showWindow(nil); transferWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func chooseUploads() {
        guard let connection = profile, !path.isEmpty else { return }
        let directory = path
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] result in
            if result == .OK { self?.transfers.add(panel.urls, connection: connection, directory: directory) }
        }
    }
    func stopTransfers() { transfers.shutdown() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !busy, !filtering, let connection = profile, visible.indices.contains(row),
              visible[row].attributes.isRegular || visible[row].attributes.isDirectory,
              RemoteEntry.isSafeName(visible[row].name) else { return nil }
        let entry = visible[row]
        let type = entry.attributes.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.conforms(to: .data) || type.conforms(to: .directory) ? type.identifier : UTType.data.identifier, delegate: self)
        provider.userInfo = PromisedDownload(connection: connection, remote: childPath(entry.name), transfers: transfers)
        return provider
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        ((provider.userInfo as! PromisedDownload).remote as NSString).lastPathComponent
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A cancelled drag has no receiver; don't leave file promises waiting at app exit.
        if operation.isEmpty { session.draggingPasteboard.clearContents() }
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let download = provider.userInfo as? PromisedDownload else {
            completionHandler(RemoteError("下载来源已失效，请重新拖出文件。")); return
        }
        do {
            try download.transfers.download(download.remote, connection: download.connection, to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard profile != nil, !path.isEmpty, !busy, !filtering else { return [] }
        let folder = visible.indices.contains(row) && visible[row].attributes.isDirectory
        tableView.setDropRow(folder ? row : -1, dropOperation: folder ? .on : .above)
        status.stringValue = "上传到：" + (folder ? childPath(visible[row].name) : path)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let connection = profile, !path.isEmpty, !busy, !filtering,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let directory = visible.indices.contains(row) && visible[row].attributes.isDirectory ? childPath(visible[row].name) : path
        transfers.add(urls, connection: connection, directory: directory); return true
    }

    @objc private func openClicked(_ sender: NSTableView) { open(row: sender.clickedRow) }
    @objc func openSelected() { open(row: table.selectedRow) }
    private func open(row: Int) {
        guard !busy, !filtering, client?.isUsable == true, visible.indices.contains(row) else { return }
        let entry = visible[row]; let remote = childPath(entry.name)
        if entry.attributes.isDirectory { navigate(remote); return }
        if let current = profile, let editing = transferItems.first(where: { $0.editing && $0.state != "stopped" && $0.connection.sameServer(as: current) && $0.remote == remote }) {
            NSWorkspace.shared.open(editing.local); return
        }
        if entry.attributes.isLink || entry.attributes.permissions == nil {
            run("正在读取链接…", retryRead: true) { session in try session.stat(remote) } completion: { [weak self] attributes in
                if attributes.isDirectory { self?.navigate(remote) } else { self?.download(remote, name: entry.name) }
            }
        } else { download(remote, name: entry.name) }
    }

    private func download(_ remote: String, name: String) {
        guard client != nil, let connection = profile else { return }
        let token = generation
        run("正在下载 \(name)…", retryRead: true) { session -> (URL, String?) in
            let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("RemoteFinder", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var local = root.appendingPathComponent(name)
            var lastUpdate = Date.distantPast
            do {
                try session.download(remote, to: local) { completed, total in
                    guard Date().timeIntervalSince(lastUpdate) > 0.15 else { return }; lastUpdate = Date()
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.generation == token else { return }
                        self.status.stringValue = "正在下载 \(name) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: completed), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))"
                    }
                }
            } catch { try? FileManager.default.removeItem(at: root); throw error }
            var baseline: String?
            if try isEditableText(local), try session.attributesIfPresent(remote)?.isRegular == true {
                baseline = try localFingerprint(local)
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoteFinder/Editing").appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let workingCopy = folder.appendingPathComponent(name)
                try FileManager.default.moveItem(at: local, to: workingCopy); local = workingCopy
            }
            return (local, baseline)
        } completion: { [weak self] result in
            let local = result.0
            if NSWorkspace.shared.open(local) {
                if let baseline = result.1 {
                    self?.transfers.watch(local, connection: connection, remote: remote, baseline: baseline)
                    self?.status.stringValue = "已打开 \(name) · 本地保存后自动同步"
                } else { self?.status.stringValue = "已在本地打开 \(name) · 此文件不自动同步" }
            }
            else { self?.showError("没有应用能够打开这个文件。缓存位置：\(local.path)") }
        }
    }

    private func showError(_ message: String) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "操作未完成"; alert.informativeText = String(message.prefix(6000))
        alert.addButton(withTitle: "好").toolTip = "关闭此提示"
        alert.beginSheetModal(for: window)
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter(delay: 0.12) }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRow() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilter() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let entry = visible[row]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: 13); cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false; cell.textField = field
            var leading = cell.leadingAnchor
            if id.rawValue == "name" {
                let image = NSImageView(); cell.addSubview(image); image.translatesAutoresizingMaskIntoConstraints = false; cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20)])
                leading = image.trailingAnchor
            }
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: leading, constant: 8), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = entry.name
            let key = entry.attributes.isDirectory ? "__folder" : entry.attributes.isLink ? "__link" : (entry.name as NSString).pathExtension
            if icons[key] == nil {
                if icons.count >= 256 { icons.removeAll() }
                icons[key] = entry.attributes.isDirectory ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "文件夹") : entry.attributes.isLink ? NSImage(systemSymbolName: "link", accessibilityDescription: "符号链接") : NSWorkspace.shared.icon(forFileType: key)
            }
            cell.imageView?.image = icons[key]
            cell.imageView?.contentTintColor = entry.attributes.isDirectory || entry.attributes.isLink ? teal : nil
        case "size":
            cell.textField?.stringValue = entry.attributes.isDirectory ? "—" : entry.attributes.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
        default: cell.textField?.stringValue = entry.attributes.modified.map(dateFormatter.string) ?? "—"
        }
        cell.toolTip = entry.name
        return cell
    }
}
