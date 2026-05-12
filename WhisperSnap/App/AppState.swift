import Foundation
import Observation

@Observable
final class AppState {
    var recordingState: RecordingState = .idle
    var isModelLoading: Bool = false
    var transientNotice: String?
}

enum RecordingState: Equatable {
    case idle
    case recording
    case realtimeConnecting
    case realtimeStreaming(partialText: String)
    case processing
    case done(text: String)
    case error(String)

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .realtimeConnecting: "dot.radiowaves.left.and.right"
        case .realtimeStreaming: "waveform.and.mic"
        case .processing: "waveform"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .done, .error: false
        case .recording, .realtimeConnecting, .realtimeStreaming, .processing: true
        }
    }

    var lastText: String? {
        if case .done(let text) = self { return text }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }

    var realtimeText: String? {
        if case .realtimeStreaming(let text) = self { return text }
        return nil
    }
}
