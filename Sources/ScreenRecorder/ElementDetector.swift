import AppKit
import ApplicationServices

/// Finds UI elements (sidebars, toolbars, panes, buttons…) inside other apps' windows with the
/// Accessibility API, so the area picker can highlight parts of a window, not just whole windows.
/// Needs the Accessibility permission.
@MainActor
final class ElementDetector {
    struct Element {
        var frame: CGRect  // global points, top-left origin (same space as CGWindowList)
        var name: String
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private var apps: [pid_t: AXUIElement] = [:]
    private var lastLeaf: AXUIElement?
    private var lastChain: [Element] = []

    init() {
        // Never let a slow or hung app freeze the picker (the default timeout is 6 seconds).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// The element of app `pid` at `point` and its ancestors up to the window, smallest first.
    func elements(at point: CGPoint, pid: pid_t) -> [Element] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app(pid), Float(point.x), Float(point.y), &hit) == .success,
              let leaf = hit else { return [] }
        // The pointer usually moves within the same element; skip re-walking the tree then.
        if let lastLeaf, CFEqual(lastLeaf, leaf) { return lastChain }

        var chain: [Element] = []
        var current = leaf
        for _ in 0..<40 {
            let role = Self.string(current, kAXRoleAttribute)
            if role == kAXApplicationRole { break }
            if let frame = Self.frame(of: current), frame.width >= 1, frame.height >= 1, chain.last?.frame != frame {
                chain.append(Element(frame: frame, name: Self.describe(current, role: role)))
            }
            if role == kAXWindowRole { break }
            guard let parent = Self.element(current, kAXParentAttribute) else { break }
            current = parent
        }
        lastLeaf = leaf
        lastChain = chain
        return chain
    }

    private func app(_ pid: pid_t) -> AXUIElement {
        if let app = apps[pid] { return app }
        let app = AXUIElementCreateApplication(pid)
        // Chromium and Electron apps (Chrome, Slack, VS Code…) only build their accessibility
        // tree when asked; this is the documented switch for that.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        apps[pid] = app
        return app
    }

    // MARK: AX helpers

    private static func describe(_ element: AXUIElement, role: String?) -> String {
        let kind = string(element, kAXRoleDescriptionAttribute) ?? role ?? "element"
        let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
        return title.isEmpty ? kind : "\(kind) “\(title.prefix(30))”"
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        if let value = attribute(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect) { return rect }
        }
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
