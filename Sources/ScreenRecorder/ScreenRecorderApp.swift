import SwiftUI

@main
struct ScreenRecorderApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        switch recorder.state {
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: "stop.circle.fill")
                Text(recorder.elapsedText).monospacedDigit()
            }
        case .paused:
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                Text(recorder.elapsedText).monospacedDigit()
            }
        case .selectingArea:
            Image(systemName: "rectangle.dashed")
        case .countingDown:
            Image(systemName: "\(recorder.countdownValue).circle.fill")
        case .capturing:
            Image(systemName: "camera.fill")
        case .starting, .stopping:
            Image(systemName: "hourglass")
        case .idle:
            Image(systemName: "record.circle")
        }
    }
}
