import SwiftUI

enum BandLoopTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.048)
    static let surface = Color(red: 0.105, green: 0.105, blue: 0.092)
    static let elevated = Color(red: 0.15, green: 0.15, blue: 0.13)
    static let accent = Color(red: 0.86, green: 1.0, blue: 0.24)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.31)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 24) -> some View {
        self
            .background(BandLoopTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
    }
}
