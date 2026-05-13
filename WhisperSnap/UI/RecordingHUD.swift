import AppKit
import Combine
import SwiftUI

@Observable
final class HUDState {
    var recordingState: RecordingState = .idle
    var sessionStartedAt: Date?
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

private let panelWidth:  CGFloat = 320
private let panelHeight: CGFloat = 120

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
        updateSessionStart(for: recordingState)
        withAnimation(.bouncy) {
            state.recordingState = recordingState
        }
        if panel == nil {
            createAndShowPanel()
        } else {
            if let panel {
                applyWindowLevel(panel, for: recordingState)
                positionPanel(panel)
            }
            panel?.orderFront(nil)
        }
    }

    private func createAndShowPanel() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        applyWindowLevel(p, for: state.recordingState)
        p.backgroundColor = NSColor.clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
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

        positionPanel(p)
        hv.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))
        container.frame = hv.frame
        p.orderFront(nil)
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - panelWidth / 2
        let y: CGFloat

        switch state.recordingState {
        case .realtimeConnecting, .realtimeStreaming:
            // Realtime: "Dynamic Island" style, colado no topo/menu bar.
            y = screen.frame.maxY - panelHeight
        default:
            // Modo normal: posição antiga, abaixo da menu bar.
            y = screen.visibleFrame.maxY - panelHeight - 4
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)
    }

    private func applyWindowLevel(_ panel: NSPanel, for recordingState: RecordingState) {
        switch recordingState {
        case .realtimeConnecting, .realtimeStreaming:
            panel.level = NSWindow.Level.statusBar
        default:
            panel.level = NSWindow.Level.floating
        }
    }

    private func updateSessionStart(for newState: RecordingState) {
        let wasActive = state.recordingState.isActive
        let isActive = newState.isActive

        if !wasActive && isActive {
            state.sessionStartedAt = Date()
        } else if wasActive && !isActive {
            state.sessionStartedAt = nil
        }
    }
}

private struct RecordingHUDView: View {
    @Environment(HUDState.self) private var hudState
    @Namespace private var namespace
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    hudContent
                }
            } else {
                ZStack {
                    hudContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, topPadding)
        .onReceive(ticker) { tick in
            now = tick
        }
    }

    @ViewBuilder
    private var hudContent: some View {
        switch hudState.recordingState {
        case .recording:
            HStack(spacing: 10) {
                WaveformBars()
                Text(timeString(elapsedSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .hudCapsuleStyle(namespace: namespace)

        case .realtimeConnecting:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RealtimeBadgeLogo()
                    Text(timeString(elapsedSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Connecting realtime transcription…")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: 320)
            .hudCapsuleStyle(namespace: namespace)

        case .realtimeStreaming(let partialText):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RealtimeBadgeLogo()
                    Text(timeString(elapsedSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(partialText.isEmpty ? "Listening…" : realtimeTailText(from: partialText))
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: 320)
            .hudCapsuleStyle(namespace: namespace)

        case .processing:
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .symbolEffect(.variableColor.iterative.reversing)
                    .foregroundStyle(.primary)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .hudCapsuleStyle(namespace: namespace)

        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("Copied to clipboard")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 300)
            .hudCapsuleStyle(namespace: namespace)

        default:
            Color.clear
                .frame(width: 76, height: 12)
                .hudCapsuleStyle(namespace: namespace, tinted: true)
        }
    }

    private var elapsedSeconds: TimeInterval {
        guard hudState.recordingState.isActive,
              let startedAt = hudState.sessionStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    private var topPadding: CGFloat {
        switch hudState.recordingState {
        case .realtimeConnecting, .realtimeStreaming:
            0
        default:
            4
        }
    }

    private func realtimeTailText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count > 40 else { return trimmed }
        let tail = words.suffix(40).joined(separator: " ")
        return "… " + tail
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private extension View {
    @ViewBuilder
    func hudCapsuleStyle(namespace: Namespace.ID, tinted: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if tinted {
                self
                    .glassEffect(.regular.tint(Color.primary.opacity(0.35)), in: .capsule)
                    .glassEffectID("hud", in: namespace)
            } else {
                self
                    .glassEffect(in: .capsule)
                    .glassEffectID("hud", in: namespace)
            }
        } else {
            self
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

private struct RealtimeBadgeLogo: View {
    var body: some View {
        Image("Dock")
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
