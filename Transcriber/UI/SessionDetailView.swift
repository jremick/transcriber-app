import SwiftData
import SwiftUI

/// Read-only view of a past session: transcript left, notes right.
struct SessionDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let sessionID: PersistentIdentifier

    private var session: MeetingSession? {
        modelContext.model(for: sessionID) as? MeetingSession
    }

    var body: some View {
        if let session {
            HSplitView {
                pastTranscript(session)
                    .frame(minWidth: 380, idealWidth: 620)
                    .layoutPriority(1)
                pastNotes(session)
                    .frame(minWidth: 300, idealWidth: 420)
            }
            .navigationTitle(session.title)
            .navigationSubtitle(
                "\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(FormatStyle.clock(session.duration))"
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        export(session)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export transcript and notes as Markdown")
                }
            }
        } else {
            ContentUnavailableView("Session Not Found", systemImage: "questionmark.folder")
        }
    }

    private func pastTranscript(_ session: MeetingSession) -> some View {
        let speakerByKey = Dictionary(uniqueKeysWithValues: session.speakers.map { ($0.key, $0) })
        let ordered = session.segments.sorted { $0.startOffset < $1.startOffset }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(ordered) { segment in
                    let speaker = speakerByKey[segment.speakerKey]
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Theme.speakerColor(speaker?.colorIndex ?? 0).gradient)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(speaker?.name ?? segment.speakerKey)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.speakerColor(speaker?.colorIndex ?? 0))
                                Text(FormatStyle.clock(segment.startOffset))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(.background)
    }

    private func pastNotes(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Key Notes", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if session.notesMarkdown.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "sparkles")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    MarkdownText(session.notesMarkdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .background(.thickMaterial)
    }

    private func export(_ session: MeetingSession) {
        do {
            _ = try TranscriptExporter.exportWithPanel(session: session)
        } catch {
            appState.lastError = "Couldn't export transcript: \(error.localizedDescription)"
        }
    }
}
