import Foundation

enum SanitizationMode: String, CaseIterable {
    case clean
    case organize
    case bullets

    nonisolated var displayName: String {
        switch self {
        case .clean: "Clean up filler words"
        case .organize: "Organize into paragraphs"
        case .bullets: "Convert to bullet points"
        }
    }

    nonisolated var systemPrompt: String {
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

    nonisolated static func demoSanitize(_ text: String, mode: SanitizationMode) -> String {
        let cleaned = normalizedDemoText(from: text)
        switch mode {
        case .clean:
            return cleaned
        case .organize:
            let sentences = splitSentences(cleaned)
            guard !sentences.isEmpty else { return cleaned }

            let paragraphs = stride(from: 0, to: sentences.count, by: 2).map { start in
                let end = min(start + 2, sentences.count)
                return sentences[start..<end].joined(separator: " ")
            }
            return paragraphs.joined(separator: "\n\n")
        case .bullets:
            let sentences = splitSentences(cleaned)
            let items = sentences.isEmpty ? [cleaned] : sentences
            return items.map { "- \($0)" }.joined(separator: "\n")
        }
    }

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

    nonisolated private static func normalizedDemoText(from rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fillerPatterns = [
            "\\b(um+|uh+|erm+|ah+|hmm+)\\b",
            "\\b(you know|i mean|kind of|sort of)\\b",
        ]

        for pattern in fillerPatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return rawText.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }

        if let last = text.last, !".!?".contains(last) {
            text += "."
        }

        return text
    }

    nonisolated private static func splitSentences(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { ".!?".contains($0) })
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { sentence in
                if let first = sentence.first {
                    return String(first).uppercased() + sentence.dropFirst()
                }
                return sentence
            }
    }
}
