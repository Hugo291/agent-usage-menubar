"""Ensure the permanent preview reuses rendering without stealing live menu views."""
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[1] / 'AgentUsage.swift').read_text()
start = source.index('final class MenuPreviewDocument:')
end = source.index('final class AppDelegate:', start)
swift = 'import Cocoa\nenum I18n { static func t(_ en: String, _ fr: String) -> String { en } }\n' + source[start:end]
swift += '''
let app = NSApplication.shared
let menu = NSMenu()
let attr = NSMutableAttributedString(string: "Test quota 42%", attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.systemFont(ofSize: 12)])
let attachment = NSTextAttachment()
attachment.image = NSImage(size: NSSize(width: 150, height: 6))
attr.append(NSAttributedString(attachment: attachment))
let field = NSTextField(labelWithAttributedString: attr)
field.frame = NSRect(x: 16, y: 3, width: 244, height: 18)
let original = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
original.addSubview(field)
let item = NSMenuItem(); item.view = original
menu.addItem(item)
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Preferences…", action: nil, keyEquivalent: ""))
let preview = MenuPreviewDocument(items: menu.items)
assert(preview.isFlipped && preview.frame.height > 24)
let copied = preview.subviews.first!.subviews.first as! NSTextField
assert(copied !== field && field.superview === original && item.view === original)
assert(copied.attributedStringValue.isEqual(to: field.attributedStringValue))
assert(preview.subviews.count == 3)
field.stringValue = "Test quota 99%"
let refreshed = MenuPreviewDocument(items: menu.items)
assert((refreshed.subviews.first!.subviews.first as! NSTextField).stringValue == "Test quota 99%")
assert(menu.items.count == 3, "preview must not mutate actual menu")
print("PASS: persistent preview preserves attributed bars, copies views, refreshes values and keeps menu intact")
'''
with tempfile.TemporaryDirectory(prefix='widget-menu-preview-test-') as tmp:
    root = pathlib.Path(tmp)
    path = root / 'main.swift'
    path.write_text(swift)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', str(path), '-o', str(binary), '-framework', 'Cocoa'], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
