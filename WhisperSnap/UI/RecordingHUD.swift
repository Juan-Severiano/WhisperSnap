import AppKit
import SwiftUI

@Observable
final class HUDState {
    var recordingState: RecordingState = .idle
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class RecordingHUDManager {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var resignObserver: Any?
    let state = HUDState()

    init() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.panel?.orderFront(nil)
        }
    }

    deinit {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }

    func update(recordingState: RecordingState) {
        state.recordingState = recordingState
        showPanel()
    }

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.becomesKeyOnlyIfNeeded = true
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.level = NSWindow.Level.floating
            p.backgroundColor = NSColor.clear
            p.isOpaque = false
            p.hasShadow = false
            p.collectionBehavior = NSWindow.CollectionBehavior([
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ])

            let root = AnyView(RecordingHUDView().environment(state))
            let hv = NSHostingView(rootView: root)
            hv.sizingOptions = []

            let container = PassThroughView()
            container.addSubview(hv)
            p.contentView = container
            hostingView = hv
            panel = p
        }

        reposition()
        panel?.orderFront(nil)
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }

        let size: NSSize = switch state.recordingState {
        case .recording, .processing: NSSize(width: 170, height: 44)
        default:                      NSSize(width: 80,  height: 16)
        }

        panel.setContentSize(size)
        let rect = NSRect(origin: .zero, size: size)
        hostingView?.frame = rect
        panel.contentView?.frame = rect

        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.minY + 32
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct RecordingHUDView: View {
    @Environment(HUDState.self) private var hudState
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        ZStack {
            switch hudState.recordingState {
            case .recording:
                HStack(spacing: 10) {
                    WaveformBars()
                    Text(timeString(elapsed))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(.black.opacity(0.82)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))

            case .processing:
                HStack(spacing: 9) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .symbolEffect(.variableColor.iterative.reversing)
                    Text("Transcribing…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(.black.opacity(0.82)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))

            default:
                // Thin idle bar — just a quiet signal that the app is alive.
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: hudState.recordingState == .recording)
        .padding(4)
        .task(id: hudState.recordingState) {
            guard case .recording = hudState.recordingState else {
                elapsed = 0
                return
            }
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct WaveformBars: View {
    @State private var heights: [CGFloat] = [0.5, 0.8, 1.0, 0.6, 0.4]
    @State private var isAnimating = false

    private let maxHeight: CGFloat = 14
    private let minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.red)
                    .frame(width: 3, height: minHeight + (maxHeight - minHeight) * heights[i])
            }
        }
        .frame(height: maxHeight)
        .onAppear {
            isAnimating = true
            animateBars()
        }
        .onDisappear { isAnimating = false }
    }

    private func animateBars() {
        guard isAnimating else { return }
        withAnimation(.easeInOut(duration: Double.random(in: 0.12...0.22))) {
            heights = heights.map { _ in CGFloat.random(in: 0.15...1.0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.12...0.22)) {
            animateBars()
        }
    }
}
