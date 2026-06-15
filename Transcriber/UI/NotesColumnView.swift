import SwiftUI

struct NotesColumnView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.notesMarkdown.isEmpty {
                emptyState
            } else {
                ScrollView {
                    MarkdownText(appState.notesMarkdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            if let issue = appState.notesCoordinator.lastIssue {
                Divider()
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .background(.thickMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Key Notes", systemImage: "sparkles")
                .font(.headline)
            if appState.notesCoordinator.isUpdating {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if let updated = appState.notesUpdatedAt {
                Text("Updated \(updated, format: .relative(presentation: .numeric))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.recordingState.isActive {
                Button {
                    appState.notesCoordinator.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(appState.notesCoordinator.isUpdating)
                .help("Update notes now")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label("Notes Appear Here", systemImage: "sparkles")
            } description: {
                Text(appState.recordingState.isActive
                    ? "Summarized key points will appear as the conversation develops."
                    : "Once a session is running, key points are summarized live.")
            }
            Spacer()
        }
    }
}

/// Minimal markdown renderer: headers, bullets, checkboxes, and inline styles
/// via AttributedString. Good enough for LLM note output.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, rawLine in
                line(String(rawLine))
            }
        }
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).font(.subheadline.weight(.semibold)).padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).font(.headline).padding(.top, 6)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).font(.title3.weight(.semibold)).padding(.top, 6)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: trimmed.hasPrefix("- [x] ") ? "checkmark.square" : "square")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                inline(String(trimmed.dropFirst(6)))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(String(trimmed.dropFirst(2)))
            }
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
