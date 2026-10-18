import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch recorder.state {
            case .recording, .paused: recordingSection
            case .countingDown: countdownSection
            default: settingsSection
            }

            if let message = recorder.errorMessage {
                errorBanner(message)
            }

            if recorder.state == .idle, let url = isScreenshotMode ? recorder.lastScreenshotURL : recorder.lastRecordingURL {
                lastCapture(url)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await recorder.refreshSources() }
        .onChange(of: recorder.state) { _, newState in
            // Get the panel out of the way once area selection, the countdown or recording begins.
            if [.selectingArea, .countingDown, .recording, .capturing].contains(newState) { dismiss() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("Screen Recorder").font(.headline)
            Spacer()
            Text(isScreenshotMode ? "Screenshot ⌃⌥⌘S" : "⌃⌥⌘R  ·  Area ⌃⌥⌘A")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("⌃⌥⌘R starts or stops recording. ⌃⌥⌘A selects an area to record. ⌃⌥⌘P pauses or resumes. ⌃⌥⌘S takes a screenshot of a window or area.")
        }
    }

    private var recordingSection: some View {
        let isPaused = recorder.state == .paused
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                if isPaused {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else {
                    Circle().fill(.red).frame(width: 10, height: 10)
                }
                Text(recorder.elapsedText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if isPaused {
                    Text("Paused").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button {
                    Task { await recorder.togglePause() }
                } label: {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("⌃⌥⌘P")

                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .help("⌃⌥⌘R")
            }
        }
    }

    private var countdownSection: some View {
        VStack(spacing: 10) {
            Text("Recording in \(recorder.countdownValue)…")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            Button {
                recorder.cancelCountdown()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(CaptureMode.allCases) { mode in
                    IconTile(symbol: mode.symbol, title: mode.title, subtitle: mode.subtitle, tint: mode.tint,
                             isSelected: recorder.mode == mode, help: mode.help) {
                        withAnimation(.snappy(duration: 0.2)) { recorder.mode = mode }
                    }
                }
            }

            // What to capture. The selected one takes the mode's color, so the two rows read together.
            HStack(spacing: 8) {
                ForEach(CaptureSource.allCases) { source in
                    IconTile(symbol: source.symbol, title: source.title, subtitle: source.subtitle, tint: recorder.mode.tint,
                             isSelected: recorder.source == source, compact: true, help: source.help) {
                        withAnimation(.snappy(duration: 0.2)) { recorder.source = source }
                    }
                }
            }

            sourcePicker

            if isScreenshotMode {
                screenshotSettings
            } else {
                videoSettings
            }

            Button {
                Task {
                    if isScreenshotMode { await recorder.takeScreenshot() } else { await recorder.start() }
                }
            } label: {
                Label(startButtonTitle, systemImage: isScreenshotMode ? "camera.fill" : "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(recorder.mode.tint)
            .disabled(recorder.isBusy || needsWindow)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var screenshotSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show mouse cursor", isOn: $recorder.showCursor)
            Picker("Delay", selection: $recorder.screenshotDelay) {
                Text("None").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
            .help("Time to open a menu or hover something before the screenshot is taken.")
            Toggle("Annotate right after capture", isOn: $recorder.annotateAfterCapture)
                .help("Opens the markup tools on the screenshot, right where you took it. Off: it's saved straight away, and you can click the thumbnail to annotate.")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Save to file", isOn: $recorder.saveScreenshot)
                if recorder.saveScreenshot {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(recorder.screenshotFolderName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(recorder.screenshotFolder.path)
                        Spacer(minLength: 4)
                        if recorder.screenshotFolder != Screenshot.defaultFolder {
                            Button {
                                recorder.resetScreenshotFolder()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Back to Pictures › ScreenRecorder")
                        }
                        Button("Change…") { recorder.chooseScreenshotFolder() }
                            .controlSize(.small)
                    }
                    .padding(.leading, 20)
                }
            }
            Toggle("Copy to clipboard", isOn: $recorder.copyScreenshot)
        }
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("System audio", isOn: $recorder.captureSystemAudio)
            Toggle("Microphone", isOn: $recorder.captureMicrophone)
            Toggle("Show mouse cursor", isOn: $recorder.showCursor)
            Toggle("Camera bubble", isOn: $recorder.showCamera)
            if recorder.showCamera {
                cameraControls
            }

            Picker("Frame rate", selection: $recorder.framesPerSecond) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Quality", selection: $recorder.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                if let megabytes = recorder.estimatedMegabytesPerMinute {
                    Text("Up to about \(megabytes) MB per minute, less when the screen is still.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Compatible format (H.264)", isOn: $recorder.compatibleFormat)
                .help("Plays on older PCs and devices, but files are about 50% bigger. Off uses HEVC, which plays on any Mac, iPhone and current browsers.")

            Toggle("3-second countdown", isOn: $recorder.useCountdown)
            Toggle("Show in Finder when done", isOn: $recorder.revealWhenDone)
        }
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if recorder.cameras.count > 1 {
                    Picker("Camera", selection: Binding(
                        get: { recorder.activeCameraID },
                        set: { recorder.cameraID = $0 }
                    )) {
                        ForEach(recorder.cameras, id: \.uniqueID) { camera in
                            Text(camera.localizedName).lineLimit(1).tag(Optional(camera.uniqueID))
                        }
                    }
                    .labelsHidden()
                } else {
                    Text("Drag the bubble to move it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Size", selection: $recorder.bubbleSize) {
                    ForEach(CameraBubble.Size.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }
            if recorder.source == .window {
                Text("The bubble only appears in Screen and Area recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 20)
    }

    private var isScreenshotMode: Bool { recorder.mode == .screenshot }

    private var needsWindow: Bool {
        recorder.source == .window && recorder.selectedWindowID == nil
    }

    private var startButtonTitle: String {
        if recorder.isBusy { return isScreenshotMode ? "Capturing…" : "Starting…" }
        if needsWindow { return "Choose a Window First" }
        if recorder.source == .area { return "Select Area…" }
        return isScreenshotMode ? "Take Screenshot" : "Start Recording"
    }

    @ViewBuilder
    private var sourcePicker: some View {
        switch recorder.source {
        case .display:
            if recorder.displays.count > 1 {
                Picker("Display", selection: $recorder.selectedDisplayID) {
                    ForEach(recorder.displays, id: \.displayID) { display in
                        Text(Recorder.name(of: display)).tag(Optional(display.displayID))
                    }
                }
            }
        case .window:
            HStack {
                Picker("Window", selection: $recorder.selectedWindowID) {
                    Text("Choose a window…").tag(CGWindowID?.none)
                    ForEach(recorder.windows, id: \.windowID) { window in
                        Text(Recorder.name(of: window)).lineLimit(1).tag(Optional(window.windowID))
                    }
                }
                Button {
                    Task { await recorder.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh window list")
            }
        case .area:
            VStack(alignment: .leading, spacing: 6) {
                if isScreenshotMode {
                    Text("Click a window, popup or part of a window to capture it, or drag any area.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(isOn: $recorder.reuseLastArea) {
                        HStack(spacing: 4) {
                            Text("Start from the last area")
                            if let area = recorder.selectedArea {
                                Text("\(Int(area.rect.width)) × \(Int(area.rect.height))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(recorder.selectedArea == nil)
                    Text(recorder.reuseLastArea && recorder.selectedArea != nil
                         ? "Adjust it, or click a window to pick that instead."
                         : "Click a window or popup to pick it, or drag any area.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Detect parts of windows", isOn: $recorder.detectElements)
                    .help("Highlights sidebars, toolbars, panes and other parts of a window. Scroll to step between bigger and smaller parts.")
                if recorder.detectElements && !ElementDetector.isTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Needs Accessibility access").font(.caption)
                        Spacer()
                        Button("Allow…") { ElementDetector.requestAccess() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !CGPreflightScreenCaptureAccess() {
                Button("Open Privacy Settings") { recorder.openScreenRecordingSettings() }
                    .controlSize(.small)
            }
        }
    }

    private func lastCapture(_ url: URL) -> some View {
        HStack {
            Image(systemName: isScreenshotMode ? "photo" : "film")
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
                .controlSize(.small)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .controlSize(.small)
            .help("Show in Finder")
        }
    }

    private var footer: some View {
        HStack {
            if isScreenshotMode {
                Button("Screenshots Folder") { recorder.openScreenshotsFolder() }
            } else {
                Button("Recordings Folder") { recorder.openRecordingsFolder() }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }
}

extension CaptureMode {
    var symbol: String { self == .video ? "video.fill" : "camera.viewfinder" }
    var subtitle: String { self == .video ? "Record screen & sound" : "Capture a still image" }
    var tint: Color { self == .video ? .green : .blue }
    var help: String {
        self == .video
            ? "Record a video of your screen, a window or an area"
            : "Take a screenshot of your screen, a window or an area (⌃⌥⌘S)"
    }
}

extension CaptureSource {
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }

    var subtitle: String {
        switch self {
        case .display: "Whole display"
        case .window: "One window"
        case .area: "Pick a region"
        }
    }

    var help: String {
        switch self {
        case .display: "Capture everything on one display"
        case .window: "Capture a single window, even when it's covered by others"
        case .area: "Click a window or part of one, or drag out any area"
        }
    }
}

/// A big, colorful button with an icon and a line saying what it does. Used for the mode
/// (Video / Screenshot) and, `compact`, for the source (Screen / Window / Area).
private struct IconTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let isSelected: Bool
    var compact = false
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 4 : 6) {
                ZStack {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)))
                        .frame(width: compact ? 36 : 46, height: compact ? 36 : 46)
                        .shadow(color: isSelected ? tint.opacity(0.45) : .clear, radius: 6, y: 2)
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 16 : 20, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : tint)
                        .symbolEffect(.bounce, value: isSelected)
                }
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 8 : 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.12) : Color.primary.opacity(isHovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? tint : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isHovering && !isSelected ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isHovering)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
