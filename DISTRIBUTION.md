# WhisperSnap Distribution

## Direct build

Use the `WhisperSnap Direct` scheme.

- Archive configuration: `Release`
- Intended for: `Developer ID` distribution outside the Mac App Store
- Behavior: keeps the current Accessibility-based text insertion flow

## App Store build

Use the `WhisperSnap App Store` scheme.

- Archive configuration: `ReleaseAppStore`
- Intended for: Mac App Store submission
- Behavior: disables direct insertion into other apps and uses clipboard delivery instead
- Notes: Sparkle is removed and the App Store entitlements are limited to sandbox-safe capabilities

## Why the split exists

The Mac App Store requires App Sandbox. WhisperSnap's original direct-insert workflow relies on Accessibility APIs to interact with other apps, which conflicts with the sandboxed App Store model. The App Store variant keeps transcription and clipboard delivery, while the Direct variant preserves the original insertion workflow for Developer ID distribution.
