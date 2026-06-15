import SwiftUI

enum Theme {
    /// Speaker accent palette; index 0 is reserved for "You".
    static let speakerColors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .mint, .brown,
    ]

    static func speakerColor(_ index: Int) -> Color {
        speakerColors[index % speakerColors.count]
    }
}

extension View {
    /// Monospaced-digit style used for the runtime clock.
    func clockStyle() -> some View {
        font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
    }
}
