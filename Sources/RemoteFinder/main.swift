import AppKit
import Darwin

signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared

if CommandLine.arguments.dropFirst().first == "--askpass" {
    application.setActivationPolicy(.accessory)
    let prompt = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    let mode = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""
    let confirmation = mode == "confirm" || prompt.contains("(yes/no")
    let alert = NSAlert()
    alert.messageText = confirmation ? "确认 SSH 服务器指纹" : "SSH 身份验证"
    alert.informativeText = prompt
    alert.addButton(withTitle: confirmation ? "信任并连接" : "继续").toolTip = confirmation ? "信任显示的服务器指纹并连接" : "将输入提交给系统 SSH 以继续认证"
    alert.addButton(withTitle: "取消").toolTip = "取消 SSH 身份验证"
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 26))
    if !confirmation { alert.accessoryView = field }
    let parentPID = getppid()
    let parentWatch = Timer(timeInterval: 0.3, repeats: true) { _ in
        if getppid() != parentPID { exit(1) }
    }
    RunLoop.current.add(parentWatch, forMode: .modalPanel)
    application.activate(ignoringOtherApps: true)
    if !confirmation { alert.window.initialFirstResponder = field }
    if alert.runModal() == .alertFirstButtonReturn {
        print(confirmation ? "yes" : field.stringValue)
        exit(0)
    }
    exit(1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = Bundle.main.image(forResource: "RemoteFinder")
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 RemoteFinder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 RemoteFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "连接服务器…", action: #selector(BrowserController.showConnect), keyEquivalent: "k")
        fileMenu.addItem(withTitle: "打开", action: #selector(BrowserController.openSelected), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "收藏当前目录…", action: #selector(BrowserController.saveCurrentLocation), keyEquivalent: "d")
        fileMenu.addItem(withTitle: "重命名选中项目…", action: #selector(BrowserController.renameSelected), keyEquivalent: "")
        fileMenu.addItem(withTitle: "刷新", action: #selector(BrowserController.refresh), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "前往文件夹…", action: #selector(BrowserController.focusPath), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "显示 / 隐藏隐藏文件", action: #selector(BrowserController.toggleHidden), keyEquivalent: ".")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "断开连接", action: #selector(BrowserController.disconnect), keyEquivalent: "")
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (name, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
        browser = BrowserController()
        for item in fileMenu.items { item.target = browser }
        browser?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { browser?.disconnect() }
}

let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
