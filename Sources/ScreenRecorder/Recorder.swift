import AppKit
import AVFoundation
import Carbon.HIToolbox
import OSLog
import ScreenCaptureKit

enum CaptureSource: String, CaseIterable, Identifiable {
    case display, window, area
    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }
}

enum RecorderError: LocalizedError {
    case noDisplay, noWindow, areaDisplayMissing

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to record."
        case .noWindow: "Pick a window to record (it may have been closed)."
        case .areaDisplayMissing: "The display for the selected area isn’t connected. Select the area again."
        }
    }
}

private let logger = Logger(subsystem: "com.aelhomsany.ScreenRecorder", category: "recording")

/// Owns the ScreenCaptureKit stream and writes it to disk with SCRecordingOutput,
/// which handles H.264 encoding and muxing video, system audio and microphone into one MP4.
@MainActor
final class Recorder: NSObject, ObservableObject {
    enum State { case idle, selectingArea, countingDown, starting, recording, paused, stopping }

    @Published private(set) var state: State = .idle
    @Published private(set) var countdownValue = 0
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var lastRecordingURL: URL?
    @Published var errorMessage: String?

    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var selectedArea: AreaSelection? { didSet { saveArea() } }

    // Persisted settings.
    @Published var source: CaptureSource { didSet { defaults.set(source.rawValue, forKey: "source") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "systemAudio") } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "microphone") } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "showCursor") } }
    @Published var framesPerSecond: Int { didSet { defaults.set(framesPerSecond, forKey: "fps") } }
    @Published var useCountdown: Bool { didSet { defaults.set(useCountdown, forKey: "countdown") } }
    @Published var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: "revealWhenDone") } }
    /// Open the area picker with the last area already selected (otherwise it starts empty).
    @Published var reuseLastArea: Bool { didSet { defaults.set(reuseLastArea, forKey: "reuseLastArea") } }
    /// Highlight parts of windows (sidebars, toolbars…) in the area picker. Needs Accessibility access.
    @Published var detectElements: Bool {
        didSet {
            defaults.set(detectElements, forKey: "detectElements")
            if detectElements && !ElementDetector.isTrusted { ElementDetector.requestAccess() }
        }
    }

    // Camera bubble. Always starts off so the camera light doesn't come on at launch.
    @Published var showCamera = false { didSet { if showCamera != oldValue { Task { await applyCameraSettings() } } } }
    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: "cameraID"); Task { await applyCameraSettings() } } }
    @Published var bubbleSize: CameraBubble.Size { didSet { defaults.set(bubbleSize.rawValue, forKey: "bubbleSize"); cameraBubble.setSize(bubbleSize) } }
    @Published private(set) var cameras: [AVCaptureDevice] = []
    /// The camera actually in use (may differ from `cameraID` if that one is unplugged).
    @Published private(set) var activeCameraID: String?

    private let defaults = UserDefaults.standard

    // The segment being written right now. Pausing ends it; resuming starts a new one.
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var currentURL: URL?
    private var recordingFinished = false
    private var recordingError: Error?

    // The whole recording, across pauses.
    private var outputURL: URL?
    private var workFolder: URL?
    private var segments: [URL] = []
    private var nextSegmentNumber = 1
    private var usesMicrophone = false
    private var isSwitchingSegment = false
    private var failureError: Error?
    private var endedEarlyError: Error?
    private var discardRequested = false

    private var recordedTime: TimeInterval = 0
    private var segmentStartDate: Date?
    private var timer: Timer?
    private var hotKeys: [HotKey] = []
    private let recordingControls = RecordingControls()
    private let countdownOverlay = CountdownOverlay()
    private let areaSelector = AreaSelector()
    private let areaBorder = AreaBorderOverlay()
    private let cameraBubble = CameraBubble()
    private let sink = NullStreamOutput()
    private let sinkQueue = DispatchQueue(label: "ScreenRecorder.samples")

    static let recordingsFolder = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenRecorder", isDirectory: true)

    override init() {
        defaults.register(defaults: [
            "source": CaptureSource.display.rawValue,
            "systemAudio": true,
            "microphone": false,
            "showCursor": true,
            "fps": 60,
            "countdown": true,
            "revealWhenDone": true,
            "reuseLastArea": true,
            "detectElements": true,
        ])
        source = CaptureSource(rawValue: defaults.string(forKey: "source") ?? "") ?? .display
        captureSystemAudio = defaults.bool(forKey: "systemAudio")
        captureMicrophone = defaults.bool(forKey: "microphone")
        showCursor = defaults.bool(forKey: "showCursor")
        framesPerSecond = defaults.integer(forKey: "fps")
        useCountdown = defaults.bool(forKey: "countdown")
        revealWhenDone = defaults.bool(forKey: "revealWhenDone")
        reuseLastArea = defaults.bool(forKey: "reuseLastArea")
        detectElements = defaults.bool(forKey: "detectElements")
        selectedArea = Self.loadArea(from: defaults)
        cameraID = defaults.string(forKey: "cameraID")
        bubbleSize = CameraBubble.Size(rawValue: defaults.integer(forKey: "bubbleSize")) ?? .medium
        super.init()

        // A menu bar app has no windows most of the time; don't let macOS quit it as "idle".
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar recorder stays available")

        // Global hotkeys, delivered by Carbon on the main thread:
        //   ⌃⌥⌘R  start / stop with the current mode
        //   ⌃⌥⌘A  select an area and record it
        //   ⌃⌥⌘P  pause / resume
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        hotKeys = [
            HotKey(id: 1, keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.toggle() }
                }
            },
            HotKey(id: 2, keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state == .idle else { return }
                    self.source = .area
                    Task { await self.start() }
                }
            },
            HotKey(id: 3, keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.togglePause() }
                }
            },
        ].compactMap { $0 }
    }

    var isBusy: Bool { ![.idle, .recording, .paused].contains(state) }

    // MARK: - Sources

    func refreshSources() async {
        cameras = CameraBubble.availableCameras()
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            displays = content.displays
            windows = content.windows.filter { window in
                window.windowLayer == 0
                    && window.frame.width > 80 && window.frame.height > 80
                    && !(window.title ?? "").isEmpty
                    && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .sorted { Self.name(of: $0).localizedCaseInsensitiveCompare(Self.name(of: $1)) == .orderedAscending }

            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID
                    ?? displays.first?.displayID
            }
            if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) {
                selectedWindowID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func name(of window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
    }

    static func name(of display: SCDisplay) -> String {
        displayName(display.displayID)
    }

    static func displayName(_ displayID: CGDirectDisplayID) -> String {
        screen(for: displayID)?.localizedName ?? "Display \(displayID)"
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    // MARK: - Camera bubble

    private func applyCameraSettings() async {
        guard showCamera else {
            cameraBubble.hide()
            return
        }
        guard await CameraBubble.requestAccess() else {
            showCamera = false
            errorMessage = CameraError.accessDenied.localizedDescription
            return
        }
        do {
            try cameraBubble.show(cameraID: cameraID, size: bubbleSize)
            cameras = CameraBubble.availableCameras()
            activeCameraID = cameraBubble.activeCameraID
        } catch {
            showCamera = false
            errorMessage = error.localizedDescription
        }
    }

    /// Our own windows are hidden from screen/area recordings, except the camera bubble.
    private func ownWindowsExclusion(in content: SCShareableContent) -> (apps: [SCRunningApplication], except: [SCWindow]) {
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let bubble = cameraBubble.windowID.flatMap { id in content.windows.first { $0.windowID == id } }
        return (ownApp, bubble.map { [$0] } ?? [])
    }

    // MARK: - Area

    /// Shows the area picker (pre-filled with the last area if that's turned on). Returns false if the user cancelled.
    private func selectArea() async -> Bool {
        guard state == .idle else { return false }
        state = .selectingArea
        let selection = await areaSelector.select(initial: reuseLastArea ? selectedArea : nil, detectElements: detectElements)
        state = .idle
        guard let selection else { return false }
        selectedArea = selection
        source = .area
        return true
    }

    private func saveArea() {
        guard let area = selectedArea else {
            defaults.removeObject(forKey: "area")
            return
        }
        defaults.set([
            "display": Int(area.displayID),
            "x": area.rect.minX, "y": area.rect.minY,
            "width": area.rect.width, "height": area.rect.height,
        ], forKey: "area")
    }

    private static func loadArea(from defaults: UserDefaults) -> AreaSelection? {
        guard let dict = defaults.dictionary(forKey: "area"),
              let display = dict["display"] as? Int,
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double else { return nil }
        return AreaSelection(displayID: CGDirectDisplayID(display), rect: CGRect(x: x, y: y, width: width, height: height))
    }

    // MARK: - Recording

    func toggle() async {
        switch state {
        case .idle: await start()
        case .countingDown: cancelCountdown()
        case .recording, .paused: await stop()
        case .selectingArea, .starting, .stopping: break
        }
    }

    func togglePause() async {
        switch state {
        case .recording: await pause()
        case .paused: await resume()
        default: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            errorMessage = "Screen Recording permission is needed. Turn on Screen Recorder in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
            return
        }

        // Area mode always shows the picker (optionally with the last area pre-selected), so you can
        // see exactly what will be recorded and confirm it with Return or the Record button.
        if source == .area {
            guard await selectArea() else { return }
        }

        // Ask for the mic before the countdown so the permission prompt doesn't interrupt it.
        var useMicrophone = captureMicrophone
        if useMicrophone, !(await Self.requestMicrophoneAccess()) {
            useMicrophone = false
            errorMessage = "Microphone access was denied, so this recording has no mic audio."
        }

        // Make sure the camera bubble ends up inside the recorded area.
        if source == .area, let area = selectedArea, let screen = Self.screen(for: area.displayID) {
            cameraBubble.keep(inside: screen.globalRect(fromLocal: area.rect))
        }

        if useCountdown {
            guard await runCountdown() else { return }
        }

        state = .starting
        do {
            outputURL = try Self.makeOutputURL()
            // Segments are written next to the final file (same volume, so moving one is instant)
            // and joined into it when the recording stops.
            let folder = Self.recordingsFolder.appendingPathComponent(".parts-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            workFolder = folder
            usesMicrophone = useMicrophone

            let captureRect = try await startSegment()

            state = .recording
            startClock()
            if source == .area, let area = selectedArea, let screen = Self.screen(for: area.displayID) {
                areaBorder.show(around: screen.globalRect(fromLocal: captureRect))
            }
            if let (region, screen) = recordedRegion(areaRect: captureRect) {
                recordingControls.show(for: self, below: region, on: screen)
            }
            logger.info("Recording started: \(self.outputURL?.path ?? "", privacy: .public)")
        } catch {
            logger.error("Start failed: \(String(describing: error), privacy: .public)")
            cleanUp()
            errorMessage = "Couldn’t start recording: \(error.localizedDescription)"
        }
    }

    /// Ends the current segment. Capture really stops, so the system's recording indicator goes away too.
    func pause() async {
        guard state == .recording, !isSwitchingSegment else { return }
        isSwitchingSegment = true
        defer { isSwitchingSegment = false }

        state = .paused
        pauseClock()
        await finalizeSegment()
        logger.info("Paused after \(self.segments.count) segment(s)")
    }

    /// Starts a new segment with the same source and settings. No countdown or area picker.
    func resume() async {
        guard state == .paused else { return }
        await waitForSegmentSwitch()
        guard state == .paused else { return }
        isSwitchingSegment = true
        defer { isSwitchingSegment = false }

        do {
            try await startSegment()
            // If Stop was pressed while the stream was starting, stop() finalizes this segment.
            guard state == .paused else { return }
            state = .recording
            resumeClock()
            logger.info("Resumed")
        } catch {
            logger.error("Resume failed: \(String(describing: error), privacy: .public)")
            guard state == .paused else { return }
            state = .stopping
            areaBorder.hide()
            recordingControls.hide()
            await finishRecording()
            errorMessage = "Couldn’t resume recording (\(error.localizedDescription)). What was recorded before the pause was saved."
        }
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        areaBorder.hide()
        recordingControls.hide()

        // Let a pause or resume that's in progress settle first.
        await waitForSegmentSwitch()
        await finalizeSegment()
        await finishRecording()
    }

    /// Stops the recording and deletes it.
    func discard() async {
        guard state == .recording || state == .paused else { return }
        discardRequested = true
        await stop()
    }

    /// Builds a new stream from the current settings and starts writing the next segment.
    /// Returns the captured rect (display-local points, for area mode).
    @discardableResult
    private func startSegment() async throws -> CGRect {
        guard let workFolder else { throw RecorderError.noDisplay }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter = try makeFilter(from: content)

        let config = SCStreamConfiguration()
        let captureRect: CGRect
        if source == .area, let area = selectedArea {
            // Clamp in case the display's resolution changed since the area was picked.
            captureRect = area.rect.intersection(CGRect(origin: .zero, size: filter.contentRect.size))
            config.sourceRect = captureRect
        } else {
            captureRect = filter.contentRect
        }
        let size = Self.outputSize(points: captureRect.size, scale: CGFloat(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.queueDepth = 6
        config.showsCursor = showCursor
        config.capturesAudio = captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = usesMicrophone
        config.ignoreShadowsSingleWindow = true

        let url = workFolder.appendingPathComponent("part-\(nextSegmentNumber).mp4")
        nextSegmentNumber += 1
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: outputConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // SCRecordingOutput does the writing; these no-op outputs just keep
        // ScreenCaptureKit from logging "stream output not found" for every frame.
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
        if config.capturesAudio {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sinkQueue)
        }
        if usesMicrophone {
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sinkQueue)
        }
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.currentURL = url
        self.recordingFinished = false
        self.recordingError = nil
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.recordingOutput = nil
            self.currentURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return captureRect
    }

    /// Finishes the segment being written (if any) and adds it to `segments`.
    private func finalizeSegment() async {
        guard let stream else { return }
        if let recordingOutput {
            try? stream.removeRecordingOutput(recordingOutput)
        }
        // Removing the recording output finalizes the file, and macOS then tears the stream down
        // ("connection interrupted"). When that happens stopCapture() can hang forever, so fire it
        // off without awaiting and only wait (with a timeout) for the file to be finished.
        Task { try? await stream.stopCapture() }
        await waitForRecordingToFinish()

        if let url = currentURL {
            if Self.fileSize(of: url) > 0 {
                segments.append(url)
            } else if let recordingError {
                failureError = recordingError
            }
        }
        self.stream = nil
        recordingOutput = nil
        currentURL = nil
        recordingError = nil
    }

    private func waitForSegmentSwitch() async {
        while isSwitchingSegment {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// What's being recorded, in global AppKit coordinates, plus the screen it's on.
    private func recordedRegion(areaRect: CGRect) -> (CGRect, NSScreen)? {
        switch source {
        case .display:
            guard let screen = selectedDisplayID.flatMap(Self.screen(for:)) ?? NSScreen.main else { return nil }
            return (screen.frame, screen)
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }),
                  let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
            // SCWindow frames use top-left-origin global coordinates; AppKit uses bottom-left.
            let frame = CGRect(x: window.frame.minX, y: mainHeight - window.frame.maxY,
                               width: window.frame.width, height: window.frame.height)
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
            return screen.map { (frame, $0) }
        case .area:
            guard let area = selectedArea, let screen = Self.screen(for: area.displayID) else { return nil }
            return (screen.globalRect(fromLocal: areaRect), screen)
        }
    }

    func cancelCountdown() {
        guard state == .countingDown else { return }
        state = .idle
    }

    /// Shows 3‑2‑1 over what's about to be recorded. Returns false if it was cancelled.
    private func runCountdown() async -> Bool {
        state = .countingDown
        let center = countdownCenter()
        defer { countdownOverlay.hide() }

        for value in stride(from: 3, through: 1, by: -1) {
            countdownValue = value
            countdownOverlay.show(value, centeredAt: center)
            // Sleep in short slices so cancelling feels instant.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                guard state == .countingDown else { return false }
            }
        }
        // Give the overlay a moment to disappear so it never lands in the first frame.
        countdownOverlay.hide()
        try? await Task.sleep(for: .milliseconds(100))
        return state == .countingDown
    }

    /// Center of what's being recorded, in global AppKit coordinates.
    private func countdownCenter() -> NSPoint {
        let fallback = NSScreen.main.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        switch source {
        case .display:
            guard let screen = selectedDisplayID.flatMap(Self.screen(for:)) else { return fallback }
            return NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }),
                  let mainHeight = NSScreen.screens.first?.frame.height else { return fallback }
            // SCWindow frames use top-left-origin global coordinates; AppKit uses bottom-left.
            return NSPoint(x: window.frame.midX, y: mainHeight - window.frame.midY)
        case .area:
            guard let area = selectedArea, let screen = Self.screen(for: area.displayID) else { return fallback }
            let rect = screen.globalRect(fromLocal: area.rect)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch source {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first else { throw RecorderError.noDisplay }
            // Keep our own menu panel and countdown out of the video (but not the camera bubble).
            let own = ownWindowsExclusion(in: content)
            return SCContentFilter(display: display, excludingApplications: own.apps, exceptingWindows: own.except)
        case .window:
            guard let id = selectedWindowID,
                  let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.noWindow }
            return SCContentFilter(desktopIndependentWindow: window)
        case .area:
            // Capture the whole display; sourceRect crops it to the area.
            guard let area = selectedArea,
                  let display = content.displays.first(where: { $0.displayID == area.displayID }) else {
                throw RecorderError.areaDisplayMissing
            }
            let own = ownWindowsExclusion(in: content)
            return SCContentFilter(display: display, excludingApplications: own.apps, exceptingWindows: own.except)
        }
    }

    /// Native pixel size, scaled down if needed to stay inside H.264's 4096×2304 limit.
    private static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let width = points.width * scale
        let height = points.height * scale
        let factor = min(1, 4096 / width, 4096 / height, sqrt(4096 * 2304 / (width * height)))
        func even(_ value: CGFloat) -> Int { max(2, Int(value * factor) & ~1) }
        return (even(width), even(height))
    }

    private static func makeOutputURL() throws -> URL {
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return recordingsFolder.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func waitForRecordingToFinish() async {
        for _ in 0..<50 where !recordingFinished {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func fileSize(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Joins the finished segments into the final MP4 (or deletes them when discarding).
    private func finishRecording() async {
        let parts = segments
        let earlyError = endedEarlyError

        if discardRequested {
            cleanUp() // deletes the parts folder
            logger.info("Recording discarded")
            return
        }

        guard let finalURL = outputURL, !parts.isEmpty else {
            let error = failureError ?? earlyError
            cleanUp()
            errorMessage = "Recording failed: \(error?.localizedDescription ?? "no video was saved.")"
            return
        }

        var savedURL = finalURL
        var joinMessage: String?
        do {
            try await SegmentJoiner.join(parts, into: finalURL)
        } catch {
            logger.error("Joining \(parts.count) parts failed: \(String(describing: error), privacy: .public)")
            // Never lose footage: keep the parts as separate files instead.
            let kept = Self.keepParts(parts, as: finalURL)
            savedURL = kept.first ?? finalURL
            joinMessage = "The paused parts couldn’t be joined, so they were saved as \(kept.count) separate files."
        }
        cleanUp()

        lastRecordingURL = savedURL
        if let joinMessage {
            errorMessage = joinMessage
        } else if let earlyError {
            errorMessage = "Recording ended early: \(earlyError.localizedDescription)"
        }
        logger.info("Recording saved: \(savedURL.path, privacy: .public) (\(parts.count) part(s), \(Self.fileSize(of: savedURL)) bytes)")

        if revealWhenDone {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        }
    }

    /// Moves the parts next to `finalURL` as "<name> (part N).mp4".
    private static func keepParts(_ parts: [URL], as finalURL: URL) -> [URL] {
        let base = finalURL.deletingPathExtension().lastPathComponent
        let folder = finalURL.deletingLastPathComponent()
        return parts.enumerated().compactMap { index, part in
            let destination = folder.appendingPathComponent("\(base) (part \(index + 1)).mp4")
            return (try? FileManager.default.moveItem(at: part, to: destination)) != nil ? destination : nil
        }
    }

    private func cleanUp() {
        areaBorder.hide()
        recordingControls.hide()
        timer?.invalidate()
        timer = nil
        segmentStartDate = nil
        stream = nil
        recordingOutput = nil
        currentURL = nil
        recordingError = nil
        if let workFolder {
            try? FileManager.default.removeItem(at: workFolder)
        }
        workFolder = nil
        outputURL = nil
        segments = []
        nextSegmentNumber = 1
        failureError = nil
        endedEarlyError = nil
        discardRequested = false
        state = .idle
    }

    // MARK: - Clock (counts recorded time only, not time spent paused)

    private func startClock() {
        recordedTime = 0
        segmentStartDate = Date()
        elapsedText = "00:00"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
    }

    private func pauseClock() {
        if let segmentStartDate {
            recordedTime += Date().timeIntervalSince(segmentStartDate)
        }
        segmentStartDate = nil
        updateElapsed()
    }

    private func resumeClock() {
        segmentStartDate = Date()
    }

    private func updateElapsed() {
        let running = segmentStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let total = Int(recordedTime + running)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        elapsedText = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Folder helpers

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // Delegate callbacks can arrive late, after a pause has already moved on to a new
    // segment, so they're only acted on if they belong to the current stream/output.
    fileprivate func isCurrent(stream id: ObjectIdentifier) -> Bool {
        stream.map(ObjectIdentifier.init) == id
    }

    fileprivate func isCurrent(output id: ObjectIdentifier) -> Bool {
        recordingOutput.map(ObjectIdentifier.init) == id
    }
}

// MARK: - ScreenCaptureKit delegates

extension Recorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.notice("Stream stopped: \(String(describing: error), privacy: .public)")
        // Fires when capture ends without us asking: the window closed, the display
        // disconnected, or the user hit "Stop" in the system's screen-sharing menu.
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            guard self.state == .recording, !self.isSwitchingSegment, self.isCurrent(stream: id) else { return }
            self.state = .stopping
            if (error as NSError).code != SCStreamError.userStopped.rawValue {
                self.endedEarlyError = error
            }
            self.areaBorder.hide()
            self.recordingControls.hide()
            await self.finalizeSegment()
            await self.finishRecording()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard self.isCurrent(output: id) else { return }
            self.recordingFinished = true
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        logger.notice("Recording output reported: \(String(describing: error), privacy: .public)")
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard self.isCurrent(output: id) else { return }
            self.recordingError = error
            self.recordingFinished = true
        }
    }
}

private final class NullStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
