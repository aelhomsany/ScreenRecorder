import AppKit
@preconcurrency import AVFoundation

enum CameraError: LocalizedError {
    case noCamera, accessDenied, cannotUseCamera

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera found. Connect a camera or use your iPhone as a Continuity Camera."
        case .accessDenied: "Camera access is off. Turn on Screen Recorder in System Settings → Privacy & Security → Camera."
        case .cannotUseCamera: "That camera couldn’t be started. It may be in use by another app."
        }
    }
}

/// A round, draggable, always-on-top webcam preview. It's a normal window on screen,
/// so ScreenCaptureKit records it as part of the screen (see Recorder.makeFilter).
@MainActor
final class CameraBubble: NSObject {
    enum Size: Int, CaseIterable, Identifiable {
        case small = 140, medium = 200, large = 280
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .small: "S"
            case .medium: "M"
            case .large: "L"
            }
        }
    }

    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ScreenRecorder.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDeviceID: String?
    private let defaults = UserDefaults.standard

    var isVisible: Bool { panel?.isVisible == true }
    var activeCameraID: String? { currentDeviceID }

    /// The bubble's window number, which matches SCWindow.windowID.
    var windowID: CGWindowID? { isVisible ? panel.map { CGWindowID($0.windowNumber) } : nil }

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func show(cameraID: String?, size: Size) throws {
        let cameras = Self.availableCameras()
        guard let device = cameras.first(where: { $0.uniqueID == cameraID })
            ?? AVCaptureDevice.default(for: .video)
            ?? cameras.first else { throw CameraError.noCamera }

        if device.uniqueID != currentDeviceID {
            let input: AVCaptureDeviceInput
            do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.cannotUseCamera }

            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraError.cannotUseCamera
            }
            session.addInput(input)
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            session.commitConfiguration()
            currentDeviceID = device.uniqueID
        }

        let panel = panel ?? makePanel(size: size)
        self.panel = panel
        setSize(size)
        // Mirror like a mirror, the way people expect to see themselves.
        if let connection = previewLayer?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        panel.orderFrontRegardless()

        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    func hide() {
        panel?.orderOut(nil)
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func setSize(_ size: Size) {
        guard let panel else { return }
        let side = CGFloat(size.rawValue)
        // Grow/shrink around the bubble's center so it stays where the user put it.
        let old = panel.frame
        let frame = CGRect(x: old.midX - side / 2, y: old.midY - side / 2, width: side, height: side)
        panel.setFrame(frame, display: true)
        panel.contentView?.layer?.cornerRadius = side / 2
        panel.invalidateShadow()
    }

    /// If the bubble isn't fully inside `rect` (global coordinates), tuck it into the bottom-left corner.
    func keep(inside rect: CGRect) {
        guard let panel, isVisible, !rect.contains(panel.frame) else { return }
        let side = panel.frame.width
        let inset: CGFloat = 16
        guard rect.width >= side + inset * 2, rect.height >= side + inset * 2 else { return }
        panel.setFrameOrigin(NSPoint(x: rect.minX + inset, y: rect.minY + inset))
    }

    private func makePanel(size: Size) -> NSPanel {
        let side = CGFloat(size.rawValue)
        let panel = NSPanel(
            contentRect: CGRect(origin: savedOrigin(side: side), size: CGSize(width: side, height: side)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = BubbleView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = side / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.insertSublayer(preview, at: 0)
        previewLayer = preview

        panel.contentView = view

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove), name: NSWindow.didMoveNotification, object: panel
        )
        return panel
    }

    @objc private func panelDidMove(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        defaults.set(frame.minX, forKey: "bubbleX")
        defaults.set(frame.minY, forKey: "bubbleY")
    }

    private func savedOrigin(side: CGFloat) -> CGPoint {
        if defaults.object(forKey: "bubbleX") != nil {
            let origin = CGPoint(x: defaults.double(forKey: "bubbleX"), y: defaults.double(forKey: "bubbleY"))
            let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
            // Only reuse it if it's still on a connected screen.
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { return origin }
        }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: visible.minX + 40, y: visible.minY + 40)
    }
}

/// Lets the user drag the bubble from anywhere inside it.
private final class BubbleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
