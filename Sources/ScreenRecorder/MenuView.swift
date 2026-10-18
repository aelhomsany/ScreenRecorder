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

            if let url = recorder.lastRecordingURL, recorder.state == .idle {
                lastRecording(url)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await recorder.refreshSources() }
        .onChange(of: recorder.state) { _, newState in
            // Get the panel out of the way once area selection, the countdown or recording begins.
            if [.selectingArea, .countingDown, .recording].contains(newState) { dismiss() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("Screen Recorder").font(.headline)
            Spacer()
            Text("⌃⌥⌘R  ·  Area ⌃⌥⌘A")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("⌃⌥⌘R starts or stops recording. ⌃⌥⌘A selects an area to record. ⌃⌥⌘P pauses or resumes.")
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
            Picker("Record", selection: $recorder.source) {
                ForEach(CaptureSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            sourcePicker

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

            Button {
                Task { await recorder.start() }
            } label: {
                Label(startButtonTitle, systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.isBusy || needsWindow)
            .keyboardShortcut(.defaultAction)
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

    private var needsWindow: Bool {
        recorder.source == .window && recorder.selectedWindowID == nil
    }

    private var startButtonTitle: String {
        if recorder.isBusy { return "Starting…" }
        if needsWindow { return "Choose a Window First" }
        if recorder.source == .area { return "Select Area…" }
        return "Start Recording"
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

    private func lastRecording(_ url: URL) -> some View {
        HStack {
            Image(systemName: "film")
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
            Button("Recordings Folder") { recorder.openRecordingsFolder() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }
}
