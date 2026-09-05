import Foundation

/// Semantic Todo commands shared by native menu shortcuts and the focused
/// Todo view. Keeping keys outside the view prevents shortcut drift.
enum TodoShortcut: Sendable {
    case next
    case previous
    case open
    case back
    case select
    case complete
    case dismiss
    case search
    case help
}
