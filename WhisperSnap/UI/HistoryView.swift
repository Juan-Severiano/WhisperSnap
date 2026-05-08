import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \TranscriptionRecord.timestamp, order: .reverse)
    private var records: [TranscriptionRecord]

    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""

    private var filtered: [TranscriptionRecord] {
        guard !searchText.isEmpty else { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            ($0.originalText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { record in
                        HistoryRow(record: record)
                    }
                    .onDelete(perform: deleteRecords)
                }
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search transcriptions")
            }
        }
        .navigationTitle("Transcription History")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", role: .destructive, action: clearAll)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Transcriptions Yet")
                .font(.headline)
            Text("Recordings appear here after transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filtered[index])
        }
    }

    private func clearAll() {
        for record in records {
            modelContext.delete(record)
        }
    }
}

private struct HistoryRow: View {
    let record: TranscriptionRecord
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)
                .font(.body)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(record.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(record.modelUsed.replacingOccurrences(of: "openai_whisper-", with: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if record.wasSanitized {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("AI cleaned")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }

                Spacer()

                Button(copied ? "Copied!" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
    }
}
