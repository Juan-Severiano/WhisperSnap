import AppKit
import SwiftUI

private struct WindowFocusOnAppearModifier: ViewModifier {
    @State private var trigger = UUID()

    func body(content: Content) -> some View {
        content
            .background(WindowFocusBridge(trigger: trigger))
            .onAppear {
                trigger = UUID()
            }
    }
}

private struct WindowFocusBridge: NSViewRepresentable {
    let trigger: UUID

    final class Coordinator {
        var appliedTrigger: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.appliedTrigger != trigger else { return }
        context.coordinator.appliedTrigger = trigger

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension View {
    func bringWindowToFrontOnAppear() -> some View {
        modifier(WindowFocusOnAppearModifier())
    }
}
