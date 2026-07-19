import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject var store: DictionaryStore
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictionary").font(.title2.bold())
                    Text("Words and names Prompter always spells your way.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    search = "" // a new row must be visible even mid-search
                    store.entries.insert(DictEntry(phrase: ""), at: 0)
                } label: {
                    Label("Add word", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .clickCursor()
            }
            .padding()

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List {
                ForEach($store.entries) { $entry in
                    // Empty rows stay visible so an entry being typed can't vanish
                    // mid-keystroke when it stops matching the search.
                    if search.isEmpty || entry.phrase.isEmpty || matches(entry) {
                        DictRow(entry: $entry) {
                            store.entries.removeAll { $0.id == entry.id }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Text("“Sounds like” = what the transcriber tends to hear instead. Comma-separate multiple.")
                .font(.caption).foregroundStyle(.secondary)
                .padding([.horizontal, .bottom])
        }
    }

    private func matches(_ entry: DictEntry) -> Bool {
        let q = search.lowercased()
        return entry.phrase.lowercased().contains(q)
            || entry.note.lowercased().contains(q)
            || entry.soundsLike.contains { $0.lowercased().contains(q) }
    }
}

private struct DictRow: View {
    @Binding var entry: DictEntry
    var onDelete: () -> Void

    var body: some View {
        HoverRow { hovered in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Word or phrase", text: $entry.phrase)
                    .font(.body.weight(.medium))
                    .frame(minWidth: 140, maxWidth: 180)
                ListField(placeholder: "Sounds like (comma-separated)", list: $entry.soundsLike)
                TextField("Note", text: $entry.note)
                    .frame(maxWidth: 130)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .opacity(hovered ? 1 : 0)
                .clickCursor()
                .help("Delete this word")
            }
        }
    }
}
