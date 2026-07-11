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
                    store.entries.insert(DictEntry(phrase: ""), at: 0)
                } label: {
                    Label("Add word", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding()

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List {
                ForEach($store.entries) { $entry in
                    if search.isEmpty || matches(entry) {
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Word or phrase", text: $entry.phrase)
                .font(.body.weight(.medium))
                .frame(minWidth: 140, maxWidth: 180)
            TextField("Sounds like (comma-separated)", text: Binding(
                get: { entry.soundsLike.joined(separator: ", ") },
                set: { entry.soundsLike = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            TextField("Note", text: $entry.note)
                .frame(maxWidth: 130)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}
