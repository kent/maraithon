import SwiftUI

struct TodoFilterStrip: View {
    @Binding var selection: TodoFilter
    let counts: TodoFilterCounts

    var body: some View {
        FilterCountStrip(
            selection: $selection,
            options: TodoFilter.allCases.map { filter in
                FilterCountOption(
                    value: filter,
                    title: filter.title,
                    count: counts.value(for: filter),
                    tint: tint(for: filter)
                )
            },
            accessibilityNoun: "work items"
        )
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func tint(for filter: TodoFilter) -> Color {
        switch filter {
        case .all: .accentColor
        case .open: .blue
        case .needsAction: .blue
        case .watching: .teal
        case .decisions: .purple
        case .today: .blue
        case .overdue: .orange
        case .upcoming: .indigo
        case .snoozed: .orange
        case .completed: .green
        }
    }
}
