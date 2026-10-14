// Clicks the middle of an app's focused text field, or its first one, the way a person would. Firefox
// reports a caret to Accessibility only after a real click or keystroke.
// Usage: swift click-focused-field.swift <bundle id>
import AppKit
import ApplicationServices

guard CommandLine.arguments.count == 2,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first else {
    print("usage: click-focused-field.swift <bundle id of a running app>"); exit(2)
}
app.activate()
Thread.sleep(forTimeInterval: 0.8)
func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
// A page that just loaded can take a few seconds to move focus into its editor.
func focusedTextField() -> AXUIElement? {
    guard let focused = attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let element = focused as! AXUIElement
    return ["AXTextArea", "AXTextField"].contains(attr(element, kAXRoleAttribute) as? String ?? "") ? element : nil
}
/// Firefox sometimes reports the page, not its editor, as focused. Then look for the
/// first text field in the front window instead.
func firstTextField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if ["AXTextArea", "AXTextField"].contains(attr(element, kAXRoleAttribute) as? String ?? "") { return element }
    for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let field = firstTextField(in: child, depth: depth + 1) { return field }
    }
    return nil
}
var found: AXUIElement?
for _ in 0..<10 {
    found = focusedTextField()
    if found == nil, let window = attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
       CFGetTypeID(window) == AXUIElementGetTypeID() {
        found = firstTextField(in: window as! AXUIElement)
    }
    if found != nil { break }
    Thread.sleep(forTimeInterval: 0.5)
}
guard let field = found, let positionValue = attr(field, kAXPositionAttribute), let sizeValue = attr(field, kAXSizeAttribute) else {
    print("the focused element is not a text field"); exit(1)
}
var position = CGPoint.zero, size = CGSize.zero
AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
let point = CGPoint(x: position.x + min(size.width / 2, 200), y: position.y + size.height / 2)
let source = CGEventSource(stateID: .privateState)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}
print("clicked")
