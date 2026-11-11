import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
let bar = RemotePathBar(frame: NSRect(x: 0, y: 0, width: 850, height: 32))
window.contentView!.addSubview(bar)
let path = "/srv/example/projects/team/workspace/demo-training/experiments"
bar.setPath(path); bar.isEnabled = true; bar.layoutSubtreeIfNeeded()
var navigated: String?
bar.onNavigate = { navigated = $0 }
func buttons() -> [NSButton] { bar.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton } }
assert(buttons().count == 9, "all eight levels and edit button visible")
assert(bar.hitTest(NSPoint(x: 800, y: 16)) === bar, "trailing whitespace starts editing")
buttons().first { $0.title == "team" }!.performClick(nil)
assert(navigated == "/srv/example/projects/team", "breadcrumb click navigates to exact ancestor")
bar.beginEditing()
let field = bar.subviews.compactMap { $0 as? NSTextField }.first!
assert(!field.isHidden && field.stringValue == path, "editing shows complete remote path")
field.stringValue = "/changed"
let textView = NSTextView()
_ = bar.control(field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
assert(field.isHidden && navigated == "/srv/example/projects/team", "Escape cancels without navigating")
bar.beginEditing(); field.stringValue = "../sibling with spaces"
_ = bar.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
assert(navigated == "../sibling with spaces" && field.isHidden, "Return submits unchanged text")
bar.beginEditing()
assert(field.stringValue == "../sibling with spaces", "failed input can be corrected")
bar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
assert(field.isHidden, "losing focus exits editing")
bar.setPath(path); bar.frame.size.width = 450; bar.layoutSubtreeIfNeeded()
assert(buttons().contains { $0.title == "…" }, "long paths expose ancestor menu")
assert(buttons().contains { $0.title == "experiments" }, "current directory stays visible")
bar.isEnabled = false; bar.layoutSubtreeIfNeeded(); bar.beginEditing()
assert(field.isHidden && buttons().allSatisfy { !$0.isEnabled }, "busy or disconnected state blocks navigation")
print("PASS: path bar hit targets, ancestor navigation, editing, Return, Escape, focus loss, overflow, disabled state")
