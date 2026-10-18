import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Saving, copying and announcing a captured screenshot.
enum Screenshot {
    static let folder = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenRecorder", isDirectory: true)

    /// PNG tagged with the display's pixel density, so a Retina capture opens at its on-screen size.
    static func pngData(_ image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.cannotSave
        }
        let dpi = 72 * max(scale, 1)
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.cannotSave }
        return data as Data
    }

    static func save(_ png: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: Date()))"
        // Two shots in the same second get " 2", " 3"… instead of overwriting each other.
        var url = folder.appendingPathComponent("\(base).png")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).png")
            number += 1
        }
        try png.write(to: url)
        return url
    }

    /// PNG for modern apps, plus TIFF for older ones that only read that.
    @MainActor
    static func copy(_ png: Data, image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    @MainActor
    static func playSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Grab"))?.play()
    }
}

enum ScreenshotError: LocalizedError {
    case cannotSave

    var errorDescription: String? { "The screenshot couldn’t be saved." }
}

// MARK: - Preview thumbnail

/// A thumbnail in the corner of the screen after a capture, like macOS's own: click it to open
/// the file, drag it into another app, or let it slide away after a few seconds.
@MainActor
final class ScreenshotPreview {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isHovering = false

    private static let maxSize = CGSize(width: 240, height: 170)
    private static let visibleFor: Duration = .seconds(6)

    func show(_ image: CGImage, fileURL: URL?, on screen: NSScreen) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let fit = min(Self.maxSize.width / CGFloat(image.width), Self.maxSize.height / CGFloat(image.height), 1)
        let thumbnail = CGSize(width: max(60, CGFloat(image.width) * fit), height: max(40, CGFloat(image.height) * fit))
        let view = ScreenshotPreviewView(
            image: NSImage(cgImage: image, size: thumbnail),
            size: thumbnail,
            fileURL: fileURL,
            onOpen: { [weak self] in
                if let fileURL { NSWorkspace.shared.open(fileURL) }
                self?.hide()
            },
            onClose: { [weak self] in self?.hide() },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) }
        )

        let panel = makePanel()
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        isHovering = false
        scheduleDismiss()
    }

    func hide() {
        dismissTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct ScreenshotPreviewView: View {
    let image: NSImage
    let size: CGSize
    let fileURL: URL?
    let onOpen: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .onDrag {
                    if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) { return provider }
                    return NSItemProvider(object: image)
                }
                .help(fileURL == nil ? "Copied to the clipboard · Drag into another app" : "Click to open · Drag into another app")

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.7), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .padding(6)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }
}
