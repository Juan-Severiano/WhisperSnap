import AppKit
import ApplicationServices

final class AccessibilityInserter {
    func requestPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isPermissionGranted: Bool {
        AXIsProcessTrusted()
    }

    func insert(_ text: String) throws {
        guard isPermissionGranted else {
            fallbackToClipboard(text)
            return
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard error == .success, let element = focusedElement else {
            fallbackToClipboard(text)
            return
        }

        let axElement = element as! AXUIElement
        let setError = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )

        if setError != .success {
            fallbackToClipboard(text)
        }
    }

    private func fallbackToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
