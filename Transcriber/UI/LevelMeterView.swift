import SwiftUI

/// Compact mic + system audio level indicator for the toolbar.
struct LevelMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            if appState.capture.micUnavailable {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Microphone unavailable — capturing system audio only")
                    .accessibilityLabel("Microphone unavailable")
                    .accessibilityValue("Capturing system audio only")
            } else {
                meter(icon: "mic.fill", level: appState.capture.micLevel, label: "Microphone level")
            }
            meter(icon: "speaker.wave.2.fill", level: appState.capture.systemLevel, label: "System audio level")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func meter(icon: String, level: Float, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.red : Color.green)
                        .frame(width: max(2, geo.size.width * CGFloat(min(level, 1))))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(width: 36, height: 4)
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
