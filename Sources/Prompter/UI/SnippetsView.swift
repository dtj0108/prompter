import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject var store: SnippetStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Say a trigger phrase — Prompter types the expansion. Say just the trigger by itself for an instant swap, or drop it mid-sentence and the AI expands it in place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.snippets.insert(Snippet(trigger: "", expansion: ""), at: 0)
                } label: {
                    Label("Add snippet", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)

            Divider()

            List {
                ForEach($store.snippets) { $snippet in
                    HoverRow { hovered in
                        HStack(alignment: .top, spacing: 10) {
                            TextField("Say this… (e.g. my email address)", text: $snippet.trigger)
                                .font(.body.weight(.medium))
                                .frame(width: 190)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            TextField("…and this gets typed", text: $snippet.expansion, axis: .vertical)
                                .lineLimit(1...4)
                            Button {
                                store.snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .opacity(hovered ? 1 : 0)
                            .help("Delete this snippet")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}
