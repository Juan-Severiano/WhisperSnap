import Foundation

enum RealtimeTranscriptionEvent {
    case connected
    case delta(String)
    case completed(String)
    case warning(String)
    case failed(String)
    case disconnected
}

struct RealtimeTranscriptionConfig {
    let baseURL: String
    let apiKey: String
    let modelID: String
    let language: String?
}

final class RealtimeTranscriptionService: @unchecked Sendable {
    var onEvent: ((RealtimeTranscriptionEvent) -> Void)?

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    func connect(config: RealtimeTranscriptionConfig) async throws {
        disconnect()

        let websocketURL = try makeRealtimeWebSocketURL(from: config.baseURL, modelID: config.modelID)
        var request = URLRequest(url: websocketURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.session = session
        self.socketTask = task
        onEvent?(.connected)

        try await sendSessionUpdate(config: config)
        startReceiveLoop()
    }

    func appendPCM16Bytes(_ data: Data) async throws {
        guard let socketTask else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ]
        try await sendJSON(payload, over: socketTask)
    }

    func commitInputBuffer() async throws {
        guard let socketTask else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.commit",
        ]
        try await sendJSON(payload, over: socketTask)
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil
        onEvent?(.disconnected)
    }

    // MARK: - Private

    private func startReceiveLoop() {
        guard let socketTask else { return }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socketTask.receive()
                    switch message {
                    case .string(let text):
                        self.handleIncoming(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncoming(text: text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if Task.isCancelled { break }
                    self.onEvent?(.failed(error.localizedDescription))
                    break
                }
            }
        }
    }

    private func sendSessionUpdate(config: RealtimeTranscriptionConfig) async throws {
        guard let socketTask else { return }
        var transcriptionConfig: [String: Any] = [
            "model": config.modelID,
        ]
        if let language = config.language, !language.isEmpty {
            transcriptionConfig["language"] = language
        }

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000,
                        ],
                        "transcription": transcriptionConfig,
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                        ],
                    ],
                ],
            ],
        ]

        try await sendJSON(payload, over: socketTask)
    }

    private func sendJSON(_ object: [String: Any], over socketTask: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await socketTask.send(.string(text))
    }

    private func handleIncoming(text: String) {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return
        }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let delta = json["delta"] as? String ?? ""
            onEvent?(.delta(delta))
        case "conversation.item.input_audio_transcription.completed":
            let transcript = json["transcript"] as? String ?? ""
            onEvent?(.completed(transcript))
        case "error":
            if let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                onEvent?(.failed(message))
            } else {
                onEvent?(.failed("Realtime transcription failed."))
            }
        case "session.created", "session.updated":
            break
        case "input_audio_buffer.cleared":
            break
        default:
            if let message = json["message"] as? String, !message.isEmpty {
                onEvent?(.warning(message))
            }
        }
    }

    private func makeRealtimeWebSocketURL(from baseURLString: String, modelID: String) throws -> URL {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            components.scheme = "wss"
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            components.path = "/v1/realtime"
        } else if trimmedPath.hasSuffix("v1/realtime") {
            components.path = "/" + trimmedPath
        } else if trimmedPath.hasSuffix("v1") {
            components.path = "/" + trimmedPath + "/realtime"
        } else {
            components.path = "/" + trimmedPath + "/v1/realtime"
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.lowercased() == "model" }
        queryItems.append(URLQueryItem(name: "model", value: modelID))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
