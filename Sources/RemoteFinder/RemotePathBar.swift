import AppKit

final class RemotePathBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((String) -> Void)?
    var isEnabled = false {
        didSet {
            editor.isEnabled = isEnabled
            needsLayout = true
        }
    }
    private let editor = NSTextField()
    private let crumbs = NSView()
    private let teal = NSColor(calibratedRed: 0, green: 0.48, blue: 0.46, alpha: 1)
    private var components: [RemotePathComponent] = []
    private var path = ""
    private var editing = false
    // Preserve a failed submission for correction without changing the displayed directory.
    private var submittedPath: String?
    private var hiddenIndices: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7; layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        toolTip = "点击目录名跳转；点击末尾空白编辑完整路径（⌘L）"
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isBordered = false; editor.drawsBackground = false; editor.focusRingType = .none
        editor.delegate = self; editor.isHidden = true
        editor.setAccessibilityLabel("编辑远程路径")
        editor.toolTip = "输入完整路径或相对路径 · Return 前往 · Esc 取消"
        addSubview(crumbs); addSubview(editor)
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPath(_ value: String) {
        path = value; components = RemotePathComponent.components(of: value)
        submittedPath = nil
        endEditing()
        needsLayout = true
    }

    func beginEditing() {
        guard isEnabled else { return }
        editing = true; editor.stringValue = submittedPath ?? path
        crumbs.isHidden = true; editor.isHidden = false
        updateBorder()
        editor.selectText(nil)
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        window?.makeFirstResponder(nil)
        editor.isHidden = true; crumbs.isHidden = false
        updateBorder()
    }

    override func mouseDown(with event: NSEvent) { beginEditing() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if !editing && (hit === crumbs || hit is NSImageView) { return self }
        return hit
    }

    private func updateBorder() {
        layer?.borderColor = (editing ? teal.withAlphaComponent(0.7) : NSColor.separatorColor.withAlphaComponent(0.35)).cgColor
    }

    override func layout() {
        super.layout()
        editor.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 20), height: 18)
        crumbs.frame = bounds
        crumbs.subviews.forEach { $0.removeFromSuperview() }
        guard !components.isEmpty else {
            let hint = NSTextField(labelWithString: "连接后显示目录路径")
            hint.font = .systemFont(ofSize: 12); hint.textColor = .tertiaryLabelColor
            hint.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - 20), height: 16)
            crumbs.addSubview(hint)
            return
        }
        let widths = components.enumerated().map { index, component -> CGFloat in
            let font = NSFont.systemFont(ofSize: 12, weight: index == components.count - 1 ? .semibold : .regular)
            return min(180, max(28, ceil((component.name as NSString).size(withAttributes: [.font: font]).width) + 16)) + 12
        }
        // Reserve a real click target after the last directory, even for a very long path.
        let indices = compactPathIndices(widths: widths, available: bounds.width - 68)
        hiddenIndices = components.indices.filter { !indices.contains($0) }
        var x: CGFloat = 6
        for (position, index) in indices.enumerated() {
            if position > 0 {
                let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
                separator.contentTintColor = .tertiaryLabelColor
                separator.frame = NSRect(x: x, y: (bounds.height - 10) / 2, width: 8, height: 10)
                crumbs.addSubview(separator); x += 12
            }
            let item = NSButton(title: index == -1 ? "…" : components[index].name, target: self, action: #selector(selectCrumb(_:)))
            item.tag = index; item.bezelStyle = .recessed; item.showsBorderOnlyWhileMouseInside = true
            item.font = .systemFont(ofSize: 12, weight: index == components.count - 1 ? .semibold : .regular)
            item.contentTintColor = index == components.count - 1 ? .labelColor : teal
            item.lineBreakMode = .byTruncatingMiddle; item.isEnabled = isEnabled
            item.toolTip = index == -1 ? "展开隐藏的上级目录" : "前往 \(components[index].path)"
            item.setAccessibilityLabel(index == -1 ? "隐藏的上级目录" : "前往 \(components[index].path)")
            let width = index == -1 ? 26 : widths[index] - 12
            item.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: width, height: 24)
            crumbs.addSubview(item); x += width
        }
        let edit = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑路径")!, target: self, action: #selector(editPath))
        edit.isBordered = false; edit.contentTintColor = .tertiaryLabelColor; edit.isEnabled = isEnabled
        edit.toolTip = "编辑完整路径（⌘L）"; edit.setAccessibilityLabel("编辑完整路径")
        edit.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 24) / 2, width: 24, height: 24)
        crumbs.addSubview(edit)
    }

    @objc private func editPath() { beginEditing() }

    @objc private func selectCrumb(_ sender: NSButton) {
        guard isEnabled else { return }
        if sender.tag == -1 {
            let menu = NSMenu()
            for index in hiddenIndices {
                let component = components[index]
                let item = NSMenuItem(title: component.name, action: #selector(selectAncestor(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = component.path; item.toolTip = component.path
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        } else {
            submittedPath = nil
            let destination = components[sender.tag].path
            if destination != path { onNavigate?(destination) }
        }
    }

    @objc private func selectAncestor(_ sender: NSMenuItem) {
        guard isEnabled, let destination = sender.representedObject as? String else { return }
        submittedPath = nil; onNavigate?(destination)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            submittedPath = nil; endEditing(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard isEnabled else { return true }
            let destination = editor.stringValue
            guard !destination.isEmpty, !destination.contains("\0") else { NSSound.beep(); return true }
            endEditing(); submittedPath = destination
            onNavigate?(destination)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editing { submittedPath = nil; endEditing() }
    }
}
