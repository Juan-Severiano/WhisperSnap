import Foundation

enum SanitizationMode: String, CaseIterable {
    case clean
    case organize
    case bullets

    var displayName: String {
        switch self {
        case .clean: "Clean up filler words"
        case .organize: "Organize into paragraphs"
        case .bullets: "Convert to bullet points"
        }
    }

    var systemPrompt: String {
        switch self {
        case .clean:
            "Fix punctuation, capitalization, and remove filler words (um, uh, like, you know) from the voice transcription. Keep all meaning intact. Return only the cleaned text, no commentary."
        case .organize:
            "You receive a raw voice transcription. Group related ideas into well-structured paragraphs. Fix punctuation and capitalization. Remove filler words. Return only the organized text, no headers or commentary."
        case .bullets:
            "You receive a raw voice transcription. Convert it into a clear markdown bullet list where each bullet is a distinct idea, action item, or point. Fix grammar. Remove filler words. Return only the bullet list, no commentary."
        }
    }
}

actor TextSanitizerService {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func sanitize(_ text: String, apiKey: String, mode: SanitizationMode = .clean) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": mode.systemPrompt],
                ["role": "user", "content": text],
            ],
            "max_tokens": 2048,
            "temperature": 0.2,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SanitizerError.httpError(code)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SanitizerError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum SanitizerError: LocalizedError {
        case httpError(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .httpError(let code): "OpenAI returned HTTP \(code). Check your API key."
            case .invalidResponse: "Unexpected response from OpenAI."
            }
        }
    }
}
