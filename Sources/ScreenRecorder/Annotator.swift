import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Model

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, pen, highlighter, text, step, blur
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select and move (Delete removes)"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .step: "Numbered step"
        case .blur: "Pixelate (hide sensitive info)"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .step: "1.circle"
        case .blur: "checkerboard.rectangle"
        }
    }

    var pointer: PointerStyle {
        switch self {
        case .select: .default
        case .text: .horizontalText
        default: .rectSelection
        }
    }
}

enum StrokeSize: CaseIterable, Identifiable {
    case small, medium, large
    var id: Self { self }

    var lineWidth: CGFloat {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 8
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 18
        case .medium: 28
        case .large: 44
        }
    }

    var stepRadius: CGFloat {
        switch self {
        case .small: 12
        case .medium: 16
        case .large: 22
        }
    }

    var title: String {
        switch self {
        case .small: "Thin"
        case .medium: "Medium"
        case .large: "Thick"
        }
    }
}

/// One mark on the screenshot. Points are in image points (pixels / scale), top-left origin.
struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var kind: AnnotationTool
    /// Pen/highlighter: the stroke. Arrow/shapes/pixelate: start and end. Text/step: the anchor.
    var points: [CGPoint]
    var color: Color
    var size: StrokeSize
    var text = ""
    var number = 0

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// What a click hits, and what the selection outline goes around.
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        switch kind {
        case .text:
            let font = size.fontSize
            return CGRect(x: first.x, y: first.y, width: max(font, CGFloat(text.count) * font * 0.6), height: font * 1.3)
        case .step:
            let r = size.stepRadius
            return CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return rect.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        default:
            return rect.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        }
    }

    var strokeWidth: CGFloat { kind == .highlighter ? size.lineWidth * 4 + 8 : size.lineWidth }

    /// Big enough to keep (not a stray click).
    var isMeaningful: Bool {
        switch kind {
        case .pen, .highlighter: points.count > 1
        case .text: !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .step: true
        default: rect.width >= 4 || rect.height >= 4
        }
    }

    func moved(by offset: CGSize) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
        return copy
    }
}

@MainActor
final class AnnotationModel: ObservableObject {
    static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    let image: CGImage
    let scale: CGFloat
    /// The image's size in points.
    let size: CGSize
    /// The whole screenshot, pixelated; the Pixelate tool shows it through a rectangle.
    let pixelated: CGImage?

    @Published var annotations: [Annotation] = [] { didSet { isDirty = true } }
    /// The shape being drawn right now.
    @Published var draft: Annotation?
    /// A text box being typed into.
    @Published var textDraft: Annotation?
    @Published var tool: AnnotationTool = .arrow {
        didSet {
            commitText()
            if tool != .select { selectedID = nil }
        }
    }
    @Published var color: Color = .red
    @Published var strokeSize: StrokeSize = .medium
    @Published var selectedID: UUID?
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published private(set) var redoStack: [[Annotation]] = []
    /// Esc with marks on the screenshot asks first, right in the toolbar.
    @Published var confirmingDiscard = false
    var isDirty = false

    private var dragging = false
    private var committedTextOnPress = false
    private var moveSnapshot: [Annotation]?
    private var moveOriginal: Annotation?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        pixelated = Self.pixelate(image, blockPixels: 14 * scale)
    }

    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    // MARK: Drawing with the mouse (points in image space)

    func dragChanged(start: CGPoint, location: CGPoint) {
        if !dragging {
            dragging = true
            begin(at: start)
        }
        switch tool {
        case .select:
            guard let original = moveOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
            annotations[index] = original.moved(by: CGSize(width: location.x - start.x, height: location.y - start.y))
        case .pen, .highlighter:
            draft?.points.append(location)
        case .arrow, .rectangle, .ellipse, .blur:
            draft?.points = [start, location]
        case .text, .step:
            break
        }
    }

    func dragEnded(at location: CGPoint) {
        defer {
            dragging = false
            draft = nil
            moveOriginal = nil
            moveSnapshot = nil
        }
        switch tool {
        case .select:
            if let moveSnapshot, moveSnapshot != annotations { push(moveSnapshot) }
        case .text:
            // A click that only finished the previous text box doesn't start a new one.
            guard !committedTextOnPress else { return }
            textDraft = Annotation(kind: .text, points: [location], color: color, size: strokeSize)
        case .step:
            let number = (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
            add(Annotation(kind: .step, points: [location], color: color, size: strokeSize, number: number))
        default:
            if let draft, draft.isMeaningful { add(draft) }
        }
    }

    private func begin(at point: CGPoint) {
        committedTextOnPress = textDraft != nil
        commitText()
        switch tool {
        case .select:
            let hit = annotations.last { $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
            selectedID = hit?.id
            moveOriginal = hit
            moveSnapshot = annotations
        case .pen, .highlighter, .arrow, .rectangle, .ellipse, .blur:
            draft = Annotation(kind: tool, points: [point], color: color, size: strokeSize)
        case .text, .step:
            break
        }
    }

    func commitText() {
        guard let text = textDraft else { return }
        textDraft = nil
        if text.isMeaningful { add(text) }
    }

    // MARK: Editing

    private func add(_ annotation: Annotation) {
        push(annotations)
        annotations.append(annotation)
    }

    private func push(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        redoStack = []
    }

    func setColor(_ newColor: Color) {
        color = newColor
        textDraft?.color = newColor
        updateSelected { $0.color = newColor }
    }

    func setSize(_ newSize: StrokeSize) {
        strokeSize = newSize
        textDraft?.size = newSize
        updateSelected { $0.size = newSize }
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        var updated = annotations[index]
        change(&updated)
        guard updated != annotations[index] else { return }
        push(annotations)
        annotations[index] = updated
    }

    func deleteSelected() {
        guard let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        push(annotations)
        annotations.remove(at: index)
        selectedID = nil
    }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedID = nil
    }

    // MARK: Output

    /// The screenshot with every annotation burned in, at full resolution.
    func render() -> CGImage? {
        commitText()
        let renderer = ImageRenderer(content: AnnotatedImage(model: self, factor: 1, isExport: true))
        renderer.scale = scale
        return renderer.cgImage
    }

    private static func pixelate(_ image: CGImage, blockPixels: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(blockPixels)
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}

// MARK: - Drawing

/// The screenshot plus its annotations. `factor` scales image points to view points.
private struct AnnotatedImage: View {
    @ObservedObject var model: AnnotationModel
    let factor: CGFloat
    var isExport = false

    var body: some View {
        let size = CGSize(width: model.size.width * factor, height: model.size.height * factor)
        ZStack {
            Image(decorative: model.image, scale: 1)
                .resizable()
                .interpolation(.high)
            Canvas { context, _ in
                context.scaleBy(x: factor, y: factor)
                let pixelated = model.pixelated.map { Image(decorative: $0, scale: 1) }
                for annotation in model.annotations {
                    AnnotationDrawing.draw(annotation, in: context, pixelated: pixelated, imageSize: model.size)
                }
                guard !isExport else { return }
                if let draft = model.draft {
                    AnnotationDrawing.draw(draft, in: context, pixelated: pixelated, imageSize: model.size)
                }
                if let selected = model.selected {
                    let outline = Path(roundedRect: selected.bounds.insetBy(dx: -4, dy: -4), cornerRadius: 4)
                    context.stroke(outline, with: .color(.accentColor),
                                   style: StrokeStyle(lineWidth: 1.5 / factor, dash: [5 / factor, 3 / factor]))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private enum AnnotationDrawing {
    static func draw(_ annotation: Annotation, in context: GraphicsContext, pixelated: Image?, imageSize: CGSize) {
        var context = context
        let color = annotation.color
        let width = annotation.strokeWidth
        let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        // A soft shadow keeps marks readable on both light and dark backgrounds.
        if annotation.kind != .blur && annotation.kind != .highlighter {
            context.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1))
        }

        switch annotation.kind {
        case .pen:
            context.stroke(smoothPath(annotation.points), with: .color(color), style: round)
        case .highlighter:
            context.stroke(smoothPath(annotation.points), with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round))
        case .arrow:
            drawArrow(annotation, in: context)
        case .rectangle:
            context.stroke(Path(roundedRect: annotation.rect, cornerRadius: width), with: .color(color), style: round)
        case .ellipse:
            context.stroke(Path(ellipseIn: annotation.rect), with: .color(color), style: round)
        case .blur:
            guard let pixelated else { return }
            context.clip(to: Path(annotation.rect))
            context.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
        case .text:
            guard let origin = annotation.points.first else { return }
            context.draw(
                Text(annotation.text).font(.system(size: annotation.size.fontSize, weight: .bold)).foregroundColor(color),
                at: origin, anchor: .topLeading
            )
        case .step:
            guard let center = annotation.points.first else { return }
            let r = annotation.size.stepRadius
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(color))
            context.stroke(circle, with: .color(.white), lineWidth: max(2, r / 8))
            let light = color == .white || color == .yellow
            context.draw(
                Text("\(annotation.number)").font(.system(size: r * 1.1, weight: .bold, design: .rounded))
                    .foregroundColor(light ? .black : .white),
                at: center, anchor: .center
            )
        case .select:
            break
        }
    }

    private static func drawArrow(_ annotation: Annotation, in context: GraphicsContext) {
        guard let start = annotation.points.first, let end = annotation.points.last else { return }
        let width = annotation.size.lineWidth
        let head = max(14, width * 4.5)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread))
        let right = CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread))
        // End the shaft inside the head so the tip stays sharp.
        let base = CGPoint(x: end.x - head * 0.8 * cos(angle), y: end.y - head * 0.8 * sin(angle))

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: base)
        context.stroke(shaft, with: .color(annotation.color), style: StrokeStyle(lineWidth: width, lineCap: .round))

        var tip = Path()
        tip.move(to: end)
        tip.addLine(to: left)
        tip.addLine(to: right)
        tip.closeSubpath()
        context.fill(tip, with: .color(annotation.color))
    }

    /// Curves through the midpoints, so freehand strokes look smooth rather than jagged.
    private static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

// MARK: - Annotating in place

/// Shows a fresh screenshot frozen exactly where it was captured, at its captured size, with the
/// rest of that screen dimmed and a toolbar attached, so it can be marked up on the spot.
@MainActor
final class AnnotationOverlay {
    enum Outcome { case save, copy, discard }

    private var window: NSWindow?
    private var model: AnnotationModel?
    private var completion: ((Outcome, CGImage) -> Void)?

    var isPresented: Bool { window != nil }

    /// `globalRect` is where the screenshot was on screen, in AppKit coordinates. `saveTitle` names
    /// the main button; `showsCopy` adds a separate Copy button (pointless when saving only copies).
    func present(image: CGImage, scale: CGFloat, at globalRect: CGRect, on screen: NSScreen,
                 saveTitle: String, showsCopy: Bool, completion: @escaping (Outcome, CGImage) -> Void) {
        close()
        let model = AnnotationModel(image: image, scale: scale)
        self.model = model
        self.completion = completion

        let frame = screen.frame
        let localRect = CGRect(x: globalRect.minX - frame.minX, y: frame.maxY - globalRect.maxY,
                               width: globalRect.width, height: globalRect.height)
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        // Above the menu bar and Dock, like the area picker.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: InPlaceAnnotationView(
            model: model, captureRect: localRect, saveTitle: saveTitle, showsCopy: showsCopy,
            onFinish: { [weak self] outcome in self?.finish(outcome) }
        ))
        window.alphaValue = 0
        self.window = window

        // Typing text and keyboard shortcuts need a key window.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
    }

    private func finish(_ outcome: Outcome) {
        guard let model, let completion else { return }
        model.commitText()
        // Untouched screenshots go out exactly as captured.
        let result = model.annotations.isEmpty ? model.image : (model.render() ?? model.image)
        close()
        completion(outcome, result)
    }

    private func close() {
        guard let window else { return }
        self.window = nil
        model = nil
        completion = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; window.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct InPlaceAnnotationView: View {
    @ObservedObject var model: AnnotationModel
    /// Where the screenshot was, in this screen's top-left-origin points.
    let captureRect: CGRect
    let saveTitle: String
    let showsCopy: Bool
    let onFinish: (AnnotationOverlay.Outcome) -> Void

    @State private var toolbarSize = CGSize(width: 900, height: 56)
    @State private var toolbarOffset = CGSize.zero
    @State private var toolbarDragStart = CGSize.zero
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fitted(captureRect, in: geometry.size)
            let factor = rect.width / model.size.width
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.4)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                canvas(factor: factor)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                AnnotationToolbar(
                    model: model, saveTitle: saveTitle, showsCopy: showsCopy,
                    onFinish: onFinish, onRequestDiscard: requestDiscard,
                    grip: AnyGesture(DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            toolbarOffset = CGSize(width: toolbarDragStart.width + value.translation.width,
                                                   height: toolbarDragStart.height + value.translation.height)
                        }
                        .onEnded { _ in toolbarDragStart = toolbarOffset }
                        .map { _ in () })
                )
                .fixedSize()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { toolbarSize = $0 }
                .position(toolbarCenter(below: rect, in: geometry.size))
                .offset(toolbarOffset)
            }
        }
        .ignoresSafeArea()
        .background { shortcuts }
    }

    // MARK: Layout

    /// The captured spot when it's fully on this screen (the usual case), otherwise scaled down to fit.
    private static func fitted(_ rect: CGRect, in size: CGSize) -> CGRect {
        if CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(rect) { return rect }
        let factor = min(size.width * 0.9 / rect.width, size.height * 0.8 / rect.height, 1)
        let width = rect.width * factor, height = rect.height * factor
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Under the screenshot if there's room, else above it, else floating inside its bottom edge.
    private func toolbarCenter(below rect: CGRect, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 14
        let (width, height) = (toolbarSize.width, toolbarSize.height)
        let x = min(max(rect.midX, width / 2 + 8), size.width - width / 2 - 8)
        let y: CGFloat
        if rect.maxY + gap + height <= size.height - 8 {
            y = rect.maxY + gap + height / 2
        } else if rect.minY - gap - height >= 8 {
            y = rect.minY - gap - height / 2
        } else {
            y = min(rect.maxY, size.height) - 40 - height / 2
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: Canvas

    private func canvas(factor: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            AnnotatedImage(model: model, factor: factor)
                .overlay(Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .compositingGroup()
                .shadow(color: .black.opacity(0.5), radius: 18, y: 4)

            if let draft = model.textDraft, let origin = draft.points.first {
                TextField("Type here", text: Binding(
                    get: { model.textDraft?.text ?? "" },
                    set: { model.textDraft?.text = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: draft.size.fontSize * factor, weight: .bold))
                .foregroundStyle(draft.color)
                .fixedSize()
                .frame(minWidth: 60, alignment: .leading)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                .offset(x: origin.x * factor - 2, y: origin.y * factor - 2)
                .focused($textFocused)
                .onSubmit { model.commitText() }
                .onExitCommand { model.commitText() }
                .onAppear { textFocused = true }
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(model.tool.pointer)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.confirmingDiscard = false
                    model.dragChanged(start: imagePoint(value.startLocation, factor), location: imagePoint(value.location, factor))
                }
                .onEnded { value in
                    model.dragEnded(at: imagePoint(value.location, factor))
                }
        )
    }

    private func imagePoint(_ point: CGPoint, _ factor: CGFloat) -> CGPoint {
        CGPoint(x: min(max(point.x / factor, 0), model.size.width),
                y: min(max(point.y / factor, 0), model.size.height))
    }

    // MARK: Keyboard

    private func requestDiscard() {
        if model.annotations.isEmpty || model.confirmingDiscard {
            onFinish(.discard)
        } else {
            model.confirmingDiscard = true
        }
    }

    /// Single-key tool shortcuts and the rest. All are off while typing text, so the keys reach the text box.
    private var shortcuts: some View {
        let typing = model.textDraft != nil
        return ZStack {
            Button("Discard") { requestDiscard() }
                .keyboardShortcut(.cancelAction)
            Button("Delete") { model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selectedID == nil)
            Button("Copy") { onFinish(showsCopy ? .copy : .save) }
                .keyboardShortcut("c", modifiers: .command)
            ForEach(AnnotationTool.allCases) { tool in
                Button(tool.title) { model.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [])
            }
        }
        .disabled(typing)
        .hidden()
    }
}

extension AnnotationTool {
    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .step: "n"
        case .blur: "b"
        }
    }
}

// MARK: - Toolbar

/// A floating dark HUD: tools, colors, sizes, undo/redo, then Discard / Copy / Save.
private struct AnnotationToolbar: View {
    @ObservedObject var model: AnnotationModel
    let saveTitle: String
    let showsCopy: Bool
    let onFinish: (AnnotationOverlay.Outcome) -> Void
    let onRequestDiscard: () -> Void
    let grip: AnyGesture<Void>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 18, height: 34)
                .contentShape(Rectangle())
                .gesture(grip)
                .pointerStyle(.grabIdle)
                .help("Drag to move the toolbar")

            HStack(spacing: 3) {
                ForEach(AnnotationTool.allCases) { tool in
                    HUDButton(isSelected: model.tool == tool, help: "\(tool.title)  ·  \(tool.shortcut.uppercased())") {
                        model.tool = tool
                    } label: {
                        Image(systemName: tool.symbol).font(.system(size: 15, weight: .semibold))
                    }
                }
            }

            separator

            HStack(spacing: 7) {
                ForEach(AnnotationModel.palette, id: \.self) { color in
                    ColorSwatch(color: color, isSelected: model.color == color) { model.setColor(color) }
                }
            }

            separator

            HStack(spacing: 2) {
                ForEach(StrokeSize.allCases) { size in
                    HUDButton(isSelected: model.strokeSize == size, tint: .white.opacity(0.22), help: size.title) {
                        model.setSize(size)
                    } label: {
                        Circle()
                            .fill(model.color == .black ? Color.white : model.color)
                            .frame(width: size.dot, height: size.dot)
                    }
                }
            }

            separator

            HStack(spacing: 2) {
                HUDButton(help: "Undo  ·  ⌘Z") { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .semibold))
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.undoStack.isEmpty || model.textDraft != nil)

                HUDButton(help: "Redo  ·  ⇧⌘Z") { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 14, weight: .semibold))
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.redoStack.isEmpty || model.textDraft != nil)
            }

            separator

            if model.confirmingDiscard {
                Text("Discard your annotations?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                PillButton(title: "Keep Editing", style: .plain) { model.confirmingDiscard = false }
                PillButton(title: "Discard", systemImage: "trash", style: .destructive) { onFinish(.discard) }
            } else {
                HUDButton(tint: .red, help: "Discard  ·  Esc") { onRequestDiscard() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                }
                if showsCopy {
                    PillButton(title: "Copy", systemImage: "doc.on.doc", style: .plain) { onFinish(.copy) }
                        .help("Copy to the clipboard and close  ·  ⌘C")
                }
                PillButton(title: saveTitle, systemImage: "checkmark", style: .prominent) { onFinish(.save) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.textDraft != nil)
                    .help("\(saveTitle)  ·  Return")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.18), value: model.confirmingDiscard)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 24)
    }
}

extension StrokeSize {
    var dot: CGFloat {
        switch self {
        case .small: 5
        case .medium: 9
        case .large: 14
        }
    }
}

/// A 34-pt square icon button: a glowing accent tile when selected, a soft highlight on hover.
private struct HUDButton<Label: View>: View {
    var isSelected = false
    var tint: Color = .accentColor
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 34, height: 34)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(isEnabled ? 0.85 : 0.3))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: tint.opacity(0.55), radius: 6, y: 2)
                    } else if isHovering && isEnabled {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint == .accentColor ? Color.white.opacity(0.12) : tint.opacity(0.35))
                    }
                }
                .contentShape(Rectangle())
                .scaleEffect(isSelected ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .help(help)
    }
}

private struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.gradient)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
                .scaleEffect(isSelected ? 1.12 : (isHovering ? 1.08 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

private struct PillButton: View {
    enum Style { case plain, prominent, destructive }
    let title: String
    var systemImage: String?
    let style: Style
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(.white)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(style == .plain ? 0.15 : 0), lineWidth: 1))
            .brightness(isHovering ? 0.08 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .plain: AnyShapeStyle(Color.white.opacity(isHovering ? 0.18 : 0.1))
        case .prominent: AnyShapeStyle(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        case .destructive: AnyShapeStyle(LinearGradient(colors: [.red, .red.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }
}
