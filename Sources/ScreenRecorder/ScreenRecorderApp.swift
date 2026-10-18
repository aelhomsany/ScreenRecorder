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
                icon(.recording)
                Text(recorder.elapsedText).monospacedDigit()
            }
        case .paused:
            HStack(spacing: 4) {
                icon(.paused)
                Text(recorder.elapsedText).monospacedDigit()
            }
        case .selectingArea:
            icon(.selecting(recorder.mode))
        case .countingDown:
            icon(.countdown(recorder.countdownValue, recorder.mode))
        case .capturing:
            icon(.capturing)
        case .starting, .stopping:
            icon(.busy)
        case .idle:
            icon(.idle)
        }
    }

    private func icon(_ badge: MenuBarIcon.Badge) -> some View {
        Image(nsImage: MenuBarIcon.image(badge)).renderingMode(.original)
    }
}
