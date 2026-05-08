import AVFoundation
import Foundation

// Thread-safe buffer for audio samples accumulated in the tap callback.
// Fully nonisolated so it can be created and called from any actor/thread context.
// Thread safety is provided explicitly by NSLock.
private final class AudioFloatBuffer: @unchecked Sendable {
    nonisolated(unsafe) private var storage: [Float] = []
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func append(_ floats: [Float]) {
        lock.withLock { storage.append(contentsOf: floats) }
    }

    nonisolated func drain() -> [Float] {
        lock.withLock {
            let result = storage
            storage = []
            return result
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case engineStartFailed(Error)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .engineStartFailed(let e): "Audio engine failed to start: \(e.localizedDescription)"
        case .conversionFailed: "Failed to convert audio format for transcription."
        }
    }
}

actor AudioCaptureManager {
    private var audioEngine: AVAudioEngine?
    private var buffer = AudioFloatBuffer()

    static let targetSampleRate: Double = 16_000

    func startRecording() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.conversionFailed
        }

        self.buffer = AudioFloatBuffer()
        let buf = self.buffer

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { pcmBuffer, _ in
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio + 1)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

            var inputConsumed = false
            var convertError: NSError?
            converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return pcmBuffer
            }

            guard let channelData = outBuffer.floatChannelData else { return }
            let floats = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
            buf.append(floats)
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stopRecording() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        return buffer.drain()
    }
}
