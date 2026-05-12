import AppKit
import KeyboardShortcuts

// Shortcut behaviour:
//  • Double-tap Option  → toggle recording (start or stop)
//  • Hold Option        → record while held; release to stop
enum ShortcutManager {

    // MARK: - Tuning

    private static let holdThreshold:    TimeInterval = 0.22   // secs before "hold" fires
    private static let doubleTapWindow:  TimeInterval = 0.35   // max gap between two taps

    // MARK: - State

    private enum OptionState {
        case idle
        case holdPending                    // Option is down, not yet committed
        case firstTapUp(releasedAt: Date)   // one tap done, waiting for second
        case holding                        // recording in hold-to-talk mode
    }

    private static var optionState: OptionState = .idle
    private static var optionWasDown = false

    private static var holdWorkItem:      DispatchWorkItem?
    private static var expireWorkItem:    DispatchWorkItem?

    private static var eventMonitor: Any?
    private static var didRegisterRealtimeToggle = false

    // MARK: - Setup

    static func setup(coordinator: AppCoordinator) {
        if !didRegisterRealtimeToggle {
            didRegisterRealtimeToggle = true
            KeyboardShortcuts.onKeyUp(for: .toggleRealtimeMode) { [weak coordinator] in
                coordinator?.toggleRealtimeMode()
            }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let optionNow = event.modifierFlags.contains(.option)

            // Ignore spurious repeated events
            guard optionNow != optionWasDown else { return }

            // Only treat Option when no other modifier is simultaneously active —
            // avoids false triggers from Opt+Cmd, Opt+Click, etc.
            let pureOption = event.modifierFlags
                .intersection([.command, .shift, .control])
                .isEmpty

            if optionNow {
                if pureOption {
                    handleDown(coordinator: coordinator)
                } else {
                    // Mixed modifier — cancel any pending hold/tap
                    cancelPending()
                }
            } else {
                handleUp(coordinator: coordinator)
            }
            optionWasDown = optionNow
        }
    }

    // MARK: - Event handlers

    private static func handleDown(coordinator: AppCoordinator) {
        switch optionState {

        case .firstTapUp(let releasedAt):
            let elapsed = Date().timeIntervalSince(releasedAt)
            if elapsed < doubleTapWindow {
                // ✓ Double-tap confirmed
                cancelPending()
                optionState = .idle
                DispatchQueue.main.async { coordinator.toggleRecording() }
            } else {
                // Too slow — treat this press as a fresh first tap
                cancelPending()
                beginHoldPending(coordinator: coordinator)
            }

        default:
            beginHoldPending(coordinator: coordinator)
        }
    }

    private static func handleUp(coordinator: AppCoordinator) {
        switch optionState {

        case .holdPending:
            // Released before hold threshold → first half of a potential double-tap
            cancelPending()
            optionState = .firstTapUp(releasedAt: Date())
            scheduleExpiry()

        case .holding:
            // Hold released → stop recording
            optionState = .idle
            DispatchQueue.main.async { coordinator.stopIfRecording() }

        default:
            break
        }
    }

    // MARK: - Helpers

    private static func beginHoldPending(coordinator: AppCoordinator) {
        optionState = .holdPending
        let work = DispatchWorkItem {
            guard case .holdPending = optionState else { return }
            optionState = .holding
            coordinator.toggleRecording()
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private static func scheduleExpiry() {
        let work = DispatchWorkItem {
            if case .firstTapUp = optionState { optionState = .idle }
        }
        expireWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }

    private static func cancelPending() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        expireWorkItem?.cancel()
        expireWorkItem = nil
    }
}
