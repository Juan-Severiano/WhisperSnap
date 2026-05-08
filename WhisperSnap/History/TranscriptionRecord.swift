import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var originalText: String?
    var duration: TimeInterval
    var modelUsed: String
    var timestamp: Date
    var wasSanitized: Bool

    init(text: String, originalText: String? = nil, duration: TimeInterval, modelUsed: String) {
        self.id = UUID()
        self.text = text
        self.originalText = originalText
        self.duration = duration
        self.modelUsed = modelUsed
        self.timestamp = Date()
        self.wasSanitized = originalText != nil
    }
}
