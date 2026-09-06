/// Native list filters keep searches explicit and preserve standard text focus.
import SwiftUI

struct TodosFilterView: View {
    @Bindable var store: TodosStore
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.small) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, next action, or source", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        Task { await store.load() }
                    }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                        Task { await store.load() }
                    } label: {
                        Label("Clear search", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, Tokens.Spacing.xsmall)
            .background(.background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            Picker("Status", selection: Binding(
                get: { store.filter },
                set: { filter in
                    store.filter = filter
                    Task { await store.load() }
                }
            )) {
                ForEach(TodoListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)

            Button("Search") {
                Task { await store.load() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.small)
        .background(.bar)
    }

}
