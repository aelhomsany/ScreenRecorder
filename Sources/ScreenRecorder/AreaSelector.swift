import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A region of one display, in points, with a top-left origin relative to that display.
/// This is the coordinate space SCStreamConfiguration.sourceRect expects.
struct AreaSelection: Equatable {
    var displayID: CGDirectDisplayID
    var rect: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Converts a display-local, top-left-origin rect to global AppKit (bottom-left) coordinates.
    func globalRect(fromLocal rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Selecting an area

/// A window (or popup, menu, panel…) under the pointer that a click can select.
struct DetectedRegion: Equatable {
    var rect: CGRect   // display-local points, top-left origin
    var name: String
    var pid: pid_t = 0
    var app = ""
}

/// What the picked area is for. Screenshots take a plain click as final, so picking a window is one click.
enum PickerPurpose {
    case record, screenshot
}

/// Dims every screen and lets the user pick a window or popup with a click, or drag out a
/// rectangle, then adjust it (move / resize) and confirm with the floating Record button or Return.
/// Esc cancels.
@MainActor
final class AreaSelector {
    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<AreaSelection?, Never>?
    private var keys: [HotKey] = []

    /// `initial` pre-selects a previous area so it can be reused with a single Return.
    /// `detectElements` also highlights parts of windows (needs Accessibility access).
    func select(initial: AreaSelection?, detectElements: Bool, purpose: PickerPurpose = .record) async -> AreaSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // Snapshot what's on screen before our overlay goes up.
            let onScreen = Self.onScreenWindows()
            let detector = detectElements && ElementDetector.isTrusted ? ElementDetector() : nil
            windows = NSScreen.screens.compactMap { screen in
                guard let displayID = screen.displayID else { return nil }
                let window = SelectionWindow(screen: screen, displayID: displayID, purpose: purpose, selector: self)
                window.selectionView.setCandidates(
                    Self.regions(onScreen, on: displayID),
                    elements: detector,
                    displayOrigin: CGDisplayBounds(displayID).origin
                )
                return window
            }
            registerKeys()

            let initialWindow = initial.flatMap { area in windows.first { $0.displayID == area.displayID } }
            if let initial, let initialWindow {
                initialWindow.selectionView.setSelection(initial.rect)
            }

            windows.forEach { $0.orderFrontRegardless() }
            let mouse = NSEvent.mouseLocation
            let keyWindow = initialWindow ?? windows.first { $0.frame.contains(mouse) } ?? windows.first
            // The picker windows are non-activating panels, so the app you're recording keeps
            // focus and its open popups/menus stay up. Activate only if that didn't give us the keyboard.
            keyWindow?.makeKey()
            if keyWindow?.isKeyWindow == false {
                NSApp.activate()
                keyWindow?.makeKey()
            }
            windows.first { $0.frame.contains(mouse) }?.selectionView.refreshHover()
        }
    }

    /// Only one screen can hold a selection at a time.
    fileprivate func selectionBegan(in view: SelectionView) {
        for window in windows where window.selectionView !== view {
            window.selectionView.setSelection(nil)
        }
    }

    fileprivate func finish(_ result: AreaSelection?) {
        keys = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        continuation?.resume(returning: result)
        continuation = nil
    }

    /// The picker doesn't take focus from the app being recorded, so normal key events would go
    /// to that app. While the picker is open, grab the keys it uses system-wide instead.
    private func registerKeys() {
        var nextID: UInt32 = 100
        func add(_ keyCode: Int, _ modifiers: Int = 0, _ action: @escaping (AreaSelector) -> Void) {
            let hotKey = HotKey(id: nextID, keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
            nextID += 1
            if let hotKey { keys.append(hotKey) }
        }

        add(kVK_Escape) { $0.finish(nil) }
        add(kVK_Return) { $0.activeView?.confirm() }
        add(kVK_ANSI_KeypadEnter) { $0.activeView?.confirm() }
        let arrows: [(Int, UInt16)] = [(kVK_LeftArrow, 123), (kVK_RightArrow, 124), (kVK_DownArrow, 125), (kVK_UpArrow, 126)]
        let modifierSets: [(Int, NSEvent.ModifierFlags)] = [
            (0, []), (shiftKey, .shift), (optionKey, .option), (shiftKey | optionKey, [.shift, .option]),
        ]
        for (key, code) in arrows {
            for (carbon, flags) in modifierSets {
                add(key, carbon) { $0.activeView?.nudge(keyCode: code, flags: flags) }
            }
        }
    }

    /// The screen holding the selection, or else the one under the pointer.
    private var activeView: SelectionView? {
        let mouse = NSEvent.mouseLocation
        return (windows.first { $0.selectionView.hasSelection } ?? windows.first { $0.frame.contains(mouse) })?.selectionView
    }

    /// Other apps' visible windows, front to back, in global top-left-origin coordinates.
    /// Popups, menus and panels are windows too, so they're included.
    private static func onScreenWindows() -> [DetectedRegion] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.compactMap(\.displayID).map(CGDisplayBounds)

        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil } // skips menu bar icons
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            // The menu bar, Dock and similar system chrome.
            guard owner != "Window Server", owner != "Dock" else { return nil }
            // Invisible full-screen overlays above normal windows would swallow every hover.
            if layer != 0, displays.contains(where: { bounds.contains($0) }) { return nil }

            let title = entry[kCGWindowName as String] as? String ?? ""
            return DetectedRegion(rect: bounds, name: title.isEmpty ? owner : "\(owner) — \(title)", pid: pid, app: owner)
        }
    }

    /// The parts of `windows` on one display, converted to that display's local coordinates.
    private static func regions(_ windows: [DetectedRegion], on displayID: CGDirectDisplayID) -> [DetectedRegion] {
        let display = CGDisplayBounds(displayID)
        let local = CGRect(origin: .zero, size: display.size)
        return windows.compactMap { window in
            let rect = window.rect.offsetBy(dx: -display.minX, dy: -display.minY).intersection(local).integral
            guard rect.width >= 40, rect.height >= 40 else { return nil }
            return DetectedRegion(rect: rect, name: window.name, pid: window.pid, app: window.app)
        }
    }
}

private final class SelectionWindow: NSPanel {
    let displayID: CGDirectDisplayID
    let selectionView: SelectionView

    init(screen: NSScreen, displayID: CGDirectDisplayID, purpose: PickerPurpose, selector: AreaSelector) {
        self.displayID = displayID
        selectionView = SelectionView(displayID: displayID, purpose: purpose, selector: selector)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = selectionView
        initialFirstResponder = selectionView
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
    }

    /// What's under the pointer.
    private enum Target: Equatable {
        case handle(Handle), inside, outside
    }

    private enum Drag {
        case creating(start: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    private static let minimumSize: CGFloat = 20
    /// How close to an edge (on either side) still grabs it.
    private static let edgeGrab: CGFloat = 8
    private static let cornerGrab: CGFloat = 16
    /// Thickness of the corner brackets and edge grips, centered on the border.
    private static let gripThickness: CGFloat = 6

    private let displayID: CGDirectDisplayID
    private let purpose: PickerPurpose
    private weak var selector: AreaSelector?
    private var selection: CGRect?
    private var drag: Drag?
    private var hovered: Target = .outside {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    /// Windows and popups on this display, front to back.
    private var candidates: [DetectedRegion] = []
    private var elements: ElementDetector?
    private var displayOrigin = CGPoint.zero
    /// What's under the pointer, smallest first: UI elements (when Accessibility is on), then the
    /// window. `level` picks the one that's highlighted; the scroll wheel changes it.
    private var chain: [DetectedRegion] = [] {
        didSet { if chain != oldValue { needsDisplay = true } }
    }
    private var level = 0 {
        didSet { if level != oldValue { needsDisplay = true } }
    }
    private var scrollAccumulator: CGFloat = 0
    /// The window or element under the pointer, highlighted so a click selects it.
    private var detected: DetectedRegion? { chain.indices.contains(level) ? chain[level] : nil }
    /// What a plain click (rather than a drag) selects, remembered from mouse-down.
    private var clickCandidate: DetectedRegion?
    private let toolbarModel = SelectionToolbarModel()
    private var toolbar: NSHostingView<SelectionToolbar>!

    init(displayID: CGDirectDisplayID, purpose: PickerPurpose, selector: AreaSelector) {
        self.displayID = displayID
        self.purpose = purpose
        self.selector = selector
        super.init(frame: .zero)

        toolbar = NSHostingView(rootView: SelectionToolbar(
            model: toolbarModel,
            purpose: purpose,
            onCancel: { [weak self] in self?.selector?.finish(nil) },
            onRecord: { [weak self] in self?.confirm() }
        ))
        toolbar.isHidden = true
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Top-left origin, so view coordinates match the display-local space sourceRect uses.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelection(_ rect: CGRect?) {
        selection = rect
        selectionChanged()
    }

    func setCandidates(_ regions: [DetectedRegion], elements: ElementDetector?, displayOrigin: CGPoint) {
        candidates = regions
        self.elements = elements
        self.displayOrigin = displayOrigin
    }

    fileprivate var hasSelection: Bool { selection != nil }

    /// Rebuilds `chain` for the pointer position.
    private func updateChain(at point: CGPoint) {
        guard let window = candidates.first(where: { $0.rect.contains(point) }) else {
            chain = [region(at: point)]
            level = 0
            return
        }

        var regions: [DetectedRegion] = []
        if let elements {
            let global = CGPoint(x: point.x + displayOrigin.x, y: point.y + displayOrigin.y)
            for element in elements.elements(at: global, pid: window.pid) {
                // Clip to the visible part of the window (scroll views report their full content).
                let rect = element.frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
                    .intersection(window.rect).integral
                guard rect.width >= 20, rect.height >= 20, rect != window.rect,
                      regions.last?.rect != rect else { continue }
                regions.append(DetectedRegion(rect: rect, name: "\(window.app) — \(element.name)", pid: window.pid, app: window.app))
            }
        }
        regions.append(window)

        guard regions.map(\.rect) != chain.map(\.rect) else { return }
        chain = regions
        // Start at the smallest part that's big enough to be worth recording.
        level = regions.firstIndex { $0.rect.width >= 60 && $0.rect.height >= 40 } ?? regions.count - 1
        scrollAccumulator = 0
    }

    /// Scrolling steps between the element under the pointer and its bigger containers.
    override func scrollWheel(with event: NSEvent) {
        guard drag == nil, chain.count > 1 else { return }
        scrollAccumulator += event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        while abs(scrollAccumulator) >= step {
            let bigger = scrollAccumulator > 0
            scrollAccumulator -= bigger ? step : -step
            level = min(max(level + (bigger ? 1 : -1), 0), chain.count - 1)
        }
    }

    /// The front-most window under `point`, or the whole display over the desktop.
    private func region(at point: CGPoint) -> DetectedRegion {
        candidates.first { $0.rect.contains(point) } ?? DetectedRegion(rect: bounds, name: "Full screen")
    }

    private var isCreating: Bool {
        if case .creating = drag { return true }
        return false
    }

    private var validSelection: CGRect? {
        guard let rect = selection?.integral,
              rect.width >= Self.minimumSize, rect.height >= Self.minimumSize else { return nil }
        return rect
    }

    fileprivate func confirm() {
        guard let rect = validSelection else { return }
        selector?.finish(AreaSelection(displayID: displayID, rect: rect))
    }

    private func selectionChanged() {
        needsDisplay = true
        layoutToolbar()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: selector?.finish(nil)  // Esc
        case 36, 76: confirm()          // Return, Enter
        case 123, 124, 125, 126: nudge(keyCode: event.keyCode, flags: event.modifierFlags)
        default: super.keyDown(with: event)
        }
    }

    /// Arrow keys move the selection by 1 pt (10 with Shift). With Option they resize it instead.
    fileprivate func nudge(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let rect = selection, drag == nil else { return }
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        let (dx, dy): (CGFloat, CGFloat) = switch keyCode {
        case 123: (-step, 0)
        case 124: (step, 0)
        case 125: (0, step)   // down (the view is flipped)
        default: (0, -step)   // up
        }
        if flags.contains(.option) {
            var resized = rect
            resized.size.width = min(max(rect.width + dx, Self.minimumSize), bounds.width - rect.minX)
            resized.size.height = min(max(rect.height + dy, Self.minimumSize), bounds.height - rect.minY)
            selection = resized
        } else {
            selection = keptOnScreen(rect.offsetBy(dx: dx, dy: dy))
        }
        selectionChanged()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        chain = []
        hovered = .outside
    }

    /// Called when the picker opens so the cursor is right before the mouse moves.
    func refreshHover() {
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHover(at point: CGPoint) {
        guard drag == nil else { return }
        if !toolbar.isHidden, toolbar.frame.insetBy(dx: -4, dy: -4).contains(point) {
            hovered = .outside
            chain = []
            NSCursor.arrow.set()
            return
        }
        hovered = target(at: point)
        // Outside the selection, highlight the window or popup a click would pick.
        if hovered == .outside { updateChain(at: point) } else { chain = [] }
        switch hovered {
        case .handle(let handle): handle.cursor.set()
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if let rect = selection {
            switch target(at: point) {
            case .handle(let handle):
                drag = .resizing(handle, original: rect)
                handle.cursor.set()
                needsDisplay = true
                return
            case .inside:
                if event.clickCount == 2 { confirm(); return }
                drag = .moving(start: point, original: rect)
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            case .outside:
                break
            }
        }

        // Start a new selection: a drag draws one, a plain click picks the highlighted window.
        selector?.selectionBegan(in: self)
        clickCandidate = detected ?? region(at: point)
        chain = []
        drag = .creating(start: point)
        hovered = .outside
        NSCursor.crosshair.set()
        selection = nil
        selectionChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .creating(let start):
            selection = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
        case .moving(let start, let original):
            selection = keptOnScreen(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y))
            NSCursor.closedHand.set()
        case .resizing(let handle, let original):
            selection = resized(original, dragging: handle, to: point)
            handle.cursor.set()
        case nil:
            return
        }
        selectionChanged()
    }

    override func mouseUp(with event: NSEvent) {
        let wasCreating = isCreating
        drag = nil
        // A click or a tiny drag selects the window under the pointer instead of leaving a sliver.
        let clicked = wasCreating && validSelection == nil ? clickCandidate : nil
        selection = validSelection ?? clicked?.rect
        clickCandidate = nil
        selectionChanged()
        // For a screenshot, clicking a window or part is the whole job.
        if purpose == .screenshot, clicked != nil {
            confirm()
            return
        }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Geometry

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func keptOnScreen(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, 0), bounds.width - rect.width)
        rect.origin.y = min(max(rect.minY, 0), bounds.height - rect.height)
        return rect
    }

    /// Corners win over edges, and the whole length of each edge is grabbable, not just its midpoint.
    private func target(at point: CGPoint) -> Target {
        guard let rect = selection, !isCreating else { return .outside }

        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (handle, corner) in corners
        where abs(point.x - corner.x) <= Self.cornerGrab && abs(point.y - corner.y) <= Self.cornerGrab {
            return .handle(handle)
        }

        let grab = Self.edgeGrab
        let alongX = point.x >= rect.minX - grab && point.x <= rect.maxX + grab
        let alongY = point.y >= rect.minY - grab && point.y <= rect.maxY + grab
        if alongX && abs(point.y - rect.minY) <= grab { return .handle(.top) }
        if alongX && abs(point.y - rect.maxY) <= grab { return .handle(.bottom) }
        if alongY && abs(point.x - rect.minX) <= grab { return .handle(.left) }
        if alongY && abs(point.x - rect.maxX) <= grab { return .handle(.right) }
        return rect.contains(point) ? .inside : .outside
    }

    private func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint) -> CGRect {
        var (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        switch handle {
        case .topLeft: (minX, minY) = (point.x, point.y)
        case .top: minY = point.y
        case .topRight: (maxX, minY) = (point.x, point.y)
        case .right: maxX = point.x
        case .bottomRight: (maxX, maxY) = (point.x, point.y)
        case .bottom: maxY = point.y
        case .bottomLeft: (minX, maxY) = (point.x, point.y)
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Puts the toolbar under the selection, or above it, or inside its bottom edge — whichever fits.
    private func layoutToolbar() {
        guard let rect = selection, !isCreating, validSelection != nil else {
            toolbar.isHidden = true
            return
        }
        toolbarModel.sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let size = toolbar.fittingSize
        let gap: CGFloat = 16
        let x = min(max(rect.midX - size.width / 2, 8), bounds.width - size.width - 8)
        let y: CGFloat
        if rect.maxY + gap + size.height <= bounds.height - 8 {
            y = rect.maxY + gap
        } else if rect.minY - gap - size.height >= 8 {
            y = rect.minY - gap - size.height
        } else {
            y = rect.maxY - gap - size.height
        }
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        toolbar.isHidden = false
    }

    // MARK: Drawing

    /// The handle being dragged, or else the one under the pointer. It's drawn highlighted.
    private var activeHandle: Handle? {
        if case .resizing(let handle, _) = drag { return handle }
        if drag == nil, case .handle(let handle) = hovered { return handle }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        if drag == nil, let detected {
            drawDetected(detected)
        }

        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            drawBorder(rect)

            if isCreating {
                // While drawing, show the live size next to the rectangle (the toolbar takes over after).
                let labelY = rect.maxY + 22 < bounds.maxY ? rect.maxY + 16 : rect.minY - 16
                drawLabel("\(Int(rect.width)) × \(Int(rect.height))", centeredAt: CGPoint(x: rect.midX, y: labelY), fontSize: 12)
                return
            }

            drawGrips(rect)
            if drag == nil, hovered == .inside, rect.width >= 90, rect.height >= 90 {
                drawMoveBadge(at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        if drag == nil {
            drawHint(avoiding: selection)
        }
    }

    /// Un-dims the hovered window and outlines it in the accent color, with its name and size.
    private func drawDetected(_ region: DetectedRegion) {
        let rect = region.rect
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill(using: .sourceOver)

        let outline = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        outline.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        var name = region.name
        if name.count > 60 { name = String(name.prefix(57)) + "…" }
        let scrollHint = chain.count > 1 ? "  ·  Scroll for bigger/smaller" : ""
        let click = purpose == .screenshot ? "Click to capture" : "Click to select"
        let label = "\(name)  ·  \(Int(rect.width)) × \(Int(rect.height))  ·  \(click)\(scrollHint)"
        let y = rect.height > 120 ? rect.minY + 28 : rect.midY
        drawLabel(label, centeredAt: CGPoint(x: rect.midX, y: y), fontSize: 12)
    }

    /// A white line with a dark outline, so the edge stays visible over both light and dark content.
    private func drawBorder(_ rect: CGRect) {
        let outline = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 4
        NSColor.black.withAlphaComponent(0.45).setStroke()
        outline.stroke()

        let line = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        line.lineWidth = 2
        NSColor.white.setStroke()
        line.stroke()

        // Light up the edge(s) the active handle controls.
        guard let handle = activeHandle else { return }
        let highlight = NSBezierPath()
        for (from, to) in edges(for: handle, in: rect.insetBy(dx: -1, dy: -1)) {
            highlight.move(to: from)
            highlight.line(to: to)
        }
        highlight.lineWidth = 3
        highlight.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        highlight.stroke()
    }

    private func edges(for handle: Handle, in rect: CGRect) -> [(CGPoint, CGPoint)] {
        let top = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        let bottom = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
        let left = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        let right = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
        return switch handle {
        case .top: [top]
        case .bottom: [bottom]
        case .left: [left]
        case .right: [right]
        case .topLeft: [top, left]
        case .topRight: [top, right]
        case .bottomLeft: [bottom, left]
        case .bottomRight: [bottom, right]
        }
    }

    /// L-shaped brackets on the corners and short bars on the middle of each edge.
    private func drawGrips(_ rect: CGRect) {
        let t = Self.gripThickness
        let o = t / 2 // grips straddle the border
        let corner = min(24, rect.width / 3, rect.height / 3)
        let bar: CGFloat = 32

        func pieces(for handle: Handle) -> [CGRect] {
            switch handle {
            case .topLeft:
                [CGRect(x: rect.minX - o, y: rect.minY - o, width: corner, height: t),
                 CGRect(x: rect.minX - o, y: rect.minY - o, width: t, height: corner)]
            case .topRight:
                [CGRect(x: rect.maxX + o - corner, y: rect.minY - o, width: corner, height: t),
                 CGRect(x: rect.maxX - o, y: rect.minY - o, width: t, height: corner)]
            case .bottomLeft:
                [CGRect(x: rect.minX - o, y: rect.maxY - o, width: corner, height: t),
                 CGRect(x: rect.minX - o, y: rect.maxY + o - corner, width: t, height: corner)]
            case .bottomRight:
                [CGRect(x: rect.maxX + o - corner, y: rect.maxY - o, width: corner, height: t),
                 CGRect(x: rect.maxX - o, y: rect.maxY + o - corner, width: t, height: corner)]
            case .top:
                rect.width > bar + corner * 2 ? [CGRect(x: rect.midX - bar / 2, y: rect.minY - o, width: bar, height: t)] : []
            case .bottom:
                rect.width > bar + corner * 2 ? [CGRect(x: rect.midX - bar / 2, y: rect.maxY - o, width: bar, height: t)] : []
            case .left:
                rect.height > bar + corner * 2 ? [CGRect(x: rect.minX - o, y: rect.midY - bar / 2, width: t, height: bar)] : []
            case .right:
                rect.height > bar + corner * 2 ? [CGRect(x: rect.maxX - o, y: rect.midY - bar / 2, width: t, height: bar)] : []
            }
        }

        for handle in Handle.allCases {
            let path = NSBezierPath()
            for piece in pieces(for: handle) {
                path.appendRoundedRect(piece, xRadius: t / 2, yRadius: t / 2)
            }
            guard !path.isEmpty else { continue }
            // Stroke first, then fill, so the outline only shows around the outside of an L.
            path.lineWidth = 2
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
            (handle == activeHandle ? NSColor.controlAccentColor : NSColor.white).setFill()
            path.fill()
        }
    }

    private func drawMoveBadge(at center: CGPoint) {
        let diameter: CGFloat = 44
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(
            in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    /// How-to line near the top of the screen (or the bottom, if the selection is up there).
    private func drawHint(avoiding rect: CGRect?) {
        guard let rect else {
            let click = purpose == .screenshot ? "Click a window or popup to capture it" : "Click a window or popup to select it"
            drawLabel(
                "\(click)  ·  Or drag to select any area  ·  Esc to cancel",
                centeredAt: CGPoint(x: bounds.midX, y: 60), fontSize: 13
            )
            return
        }
        let action = purpose == .screenshot ? "capture" : "record"
        let text = "Drag inside to move  ·  Drag edges to resize  ·  Click a window or drag outside for a new area  ·  Return to \(action)"
        let topY: CGFloat = 60
        let bottomY = bounds.maxY - 40
        let y: CGFloat
        if rect.minY > topY + 24 {
            y = topY
        } else if rect.maxY < bottomY - 24 {
            y = bottomY
        } else {
            return
        }
        drawLabel(text, centeredAt: CGPoint(x: bounds.midX, y: y), fontSize: 13)
    }

    private func drawLabel(_ text: String, centeredAt center: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let background = CGRect(
            x: center.x - size.width / 2 - 10, y: center.y - size.height / 2 - 5,
            width: size.width + 20, height: size.height + 10
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
        string.draw(at: CGPoint(x: background.minX + 10, y: background.minY + 5), withAttributes: attributes)
    }
}

private final class SelectionToolbarModel: ObservableObject {
    @Published var sizeText = ""
}

private struct SelectionToolbar: View {
    @ObservedObject var model: SelectionToolbarModel
    let purpose: PickerPurpose
    let onCancel: () -> Void
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")

            Text(model.sizeText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button(action: onRecord) {
                Label(isScreenshot ? "Capture" : "Record", systemImage: isScreenshot ? "camera.fill" : "record.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isScreenshot ? Color.accentColor : .red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(isScreenshot ? "Take the screenshot (Return)" : "Start recording (Return)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var isScreenshot: Bool { purpose == .screenshot }
}

// MARK: - Border while recording

/// A click-through dashed outline drawn just outside the recorded area.
/// It sits outside sourceRect and belongs to our app, so it never shows up in the video.
@MainActor
final class AreaBorderOverlay {
    private var window: NSWindow?
    private static let margin: CGFloat = 4

    func show(around globalRect: CGRect) {
        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(globalRect.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView:
            Rectangle()
                .strokeBorder(.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        return window
    }
}
