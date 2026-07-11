import SwiftUI

struct StyleView: View {
    @EnvironmentObject var store: StyleStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Style").font(.title2.bold())
                    Text("How Prompter writes when it cleans up your dictation.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                GroupBox("Your voice — applies everywhere") {
                    TextEditor(text: $store.style.globalVoice)
                        .font(.body)
                        .frame(minHeight: 64)
                        .scrollContentBackground(.hidden)
                }

                Text("Contexts").font(.headline)
                Text("Prompter looks at the app you're dictating into (and the window title for browser tabs) and applies the first matching context.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach($store.style.contexts) { $ctx in
                    ContextEditor(ctx: $ctx, deletable: ctx.id != "other") {
                        store.style.contexts.removeAll { $0.id == ctx.id }
                    }
                }

                Button {
                    let newId = "custom-\(UUID().uuidString.prefix(6).lowercased())"
                    let insertAt = max(0, store.style.contexts.count - 1) // keep "other" last
                    store.style.contexts.insert(
                        ContextStyle(id: newId, name: "New context", appBundleIds: [], titleKeywords: [], instructions: ""),
                        at: insertAt
                    )
                } label: {
                    Label("Add context", systemImage: "plus")
                }
            }
            .padding(20)
        }
    }
}

private struct ContextEditor: View {
    @Binding var ctx: ContextStyle
    var deletable: Bool
    var onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $ctx.name)
                        .font(.body.weight(.semibold))
                        .textFieldStyle(.plain)
                    Spacer()
                    if deletable {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if ctx.id != "other" {
                    LabeledContent("Apps (bundle IDs)") {
                        TextField("com.tinyspeck.slackmacgap, …", text: listBinding($ctx.appBundleIds))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Title keywords") {
                        TextField("gmail, inbox, …", text: listBinding($ctx.titleKeywords))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("Tone instructions")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $ctx.instructions)
                    .font(.body)
                    .frame(minHeight: 56)
                    .scrollContentBackground(.hidden)
            }
            .padding(6)
        }
    }

    private func listBinding(_ list: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { list.wrappedValue.joined(separator: ", ") },
            set: { list.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }
}
