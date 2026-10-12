import AppKit
import SwiftUI

/// A click-through floating panel that shows a big 3‑2‑1 in the middle of a screen.
/// It belongs to our app, so the display filter keeps it out of the recording.
@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?
    private let model = Model()

    final class Model: ObservableObject {
        @Published var value = 3
    }

    /// `center` is in global AppKit (bottom-left origin) coordinates.
    func show(_ value: Int, centeredAt center: NSPoint) {
        model.value = value
        let panel = panel ?? makePanel()
        self.panel = panel

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        return panel
    }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownOverlay.Model

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.6))
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 3)
            Text("\(model.value)")
                .font(.system(size: 110, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 200, height: 200)
        .frame(width: 220, height: 220)
        .animation(.snappy, value: model.value)
    }
}
