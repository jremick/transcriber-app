import SwiftUI

struct TranscriptColumnView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.turns.isEmpty && !appState.recordingState.isActive {
                emptyState
            } else {
                transcriptList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(appState.turns) { turn in
                        SpeakerTurnRow(turn: turn)
                    }
                    volatileTail
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(16)
            }
            .onChange(of: appState.turns.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var volatileTail: some View {
        ForEach([AudioSource.microphone, .system], id: \.rawValue) { source in
            if let text = appState.volatileText[source], !text.isEmpty {
                Text(text)
                    .foregroundStyle(.secondary)
                    .opacity(0.6)
                    .padding(.leading, 36)
                    .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ready to Transcribe", systemImage: "waveform.and.mic")
        } description: {
            Text("Start a session, or join a meeting and Transcriber will offer to capture it.")
        } actions: {
            Button("Start Transcribing") {
                appState.startSession()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct SpeakerTurnRow: View {
    @Environment(AppState.self) private var appState
    let turn: SpeakerTurn
    @State private var isRenaming = false
    @State private var draftName = ""

    private var info: SpeakerInfo { appState.speakerInfo(for: turn.speaker) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SpeakerChip(info: info)
                .onTapGesture {
                    draftName = info.name
                    isRenaming = true
                }
                .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
                    renamePopover
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.speakerColor(info.colorIndex))
                    Text(FormatStyle.clock(turn.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(turn.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.name) at \(FormatStyle.clock(turn.start)): \(turn.text)")
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename Speaker")
                .font(.headline)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("Cancel") { isRenaming = false }
                Button("Rename") { commitRename() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private func commitRename() {
        appState.renameSpeaker(turn.speaker, to: draftName)
        isRenaming = false
    }
}

struct SpeakerChip: View {
    let info: SpeakerInfo

    var body: some View {
        Circle()
            .fill(Theme.speakerColor(info.colorIndex).gradient)
            .frame(width: 26, height: 26)
            .overlay {
                Text(initials)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .help("Click to rename")
    }

    private var initials: String {
        let words = info.name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
