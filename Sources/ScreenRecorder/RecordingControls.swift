import AppKit
import SwiftUI

/// A small draggable pill with the timer, Stop and Discard, shown while recording so you
/// don't need to go back to the menu bar. It's one of our own windows, so it's never recorded.
@MainActor
final class RecordingControls {
    private var panel: NSPanel?

    /// `target` is what's being recorded, in global AppKit coordinates. The bar goes just
    /// below it when there's room, otherwise inside its bottom edge.
    func show(for recorder: Recorder, below target: CGRect, on screen: NSScreen) {
        let panel = panel ?? makePanel(recorder: recorder)
        self.panel = panel

        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setContentSize(size)

        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let x = min(max(target.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        var y = target.minY - gap - size.height
        if y < visible.minY + 8 {
            y = max(target.minY, visible.minY) + 24
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(recorder: Recorder) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControlsView(recorder: recorder))
        return panel
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var recorder: Recorder
    @State private var blink = false

    private var isPaused: Bool { recorder.state == .paused }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .opacity(blink ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: blink)
                        .onAppear { blink = true }
                        .onDisappear { blink = false }
                }
            }
            .frame(width: 10)

            Text(recorder.elapsedText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isPaused ? .secondary : .primary)
                .frame(minWidth: 44, alignment: .leading)

            Button {
                Task { await recorder.discard() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop and delete this recording")

            Button {
                Task { await recorder.togglePause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Resume recording (⌃⌥⌘P)" : "Pause recording (⌃⌥⌘P)")

            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Stop recording (⌃⌥⌘R)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}
