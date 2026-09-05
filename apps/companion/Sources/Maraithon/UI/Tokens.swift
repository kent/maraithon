import SwiftUI

/// Design tokens — the only place numeric paddings, corner radii, and
/// custom colors live in the app. Reach for these instead of hardcoding
/// literal numbers in views; see `AGENTS.md` for the rationale.
enum Tokens {
    enum Spacing {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 32
    }

    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
    }

    enum IconSize {
        static let inline: CGFloat = 16
        static let regular: CGFloat = 20
        static let prominent: CGFloat = 28
        static let large: CGFloat = 56
    }

    enum Layout {
        static let onboardingMaxWidth: CGFloat = 480
        static let todoInspectorMinWidth: CGFloat = 280
        static let todoInspectorIdealWidth: CGFloat = 360
        static let todoInspectorMaxWidth: CGFloat = 480
        static let shortcutHelpMinWidth: CGFloat = 420
        static let shortcutHelpMinHeight: CGFloat = 360
    }
}

/// Status semantics — always paired with an SF Symbol; the color
/// vocabulary is small on purpose.
enum StatusTone: Equatable {
    case neutral
    case good
    case attention
    case error
    case muted

    var color: Color {
        switch self {
        case .neutral: return .accentColor
        case .good: return .green
        case .attention: return .orange
        case .error: return .red
        case .muted: return .secondary
        }
    }
}
