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
                        ListField(placeholder: "com.tinyspeck.slackmacgap, …", list: $ctx.appBundleIds)
                    }
                    LabeledContent("Title keywords") {
                        ListField(placeholder: "gmail, inbox, …", list: $ctx.titleKeywords)
                    }
                }
                HStack {
                    Text("Tone instructions")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        presetButton("Formal", StylePresets.formal)
                        presetButton("Casual", StylePresets.casual)
                        presetButton("Very casual", StylePresets.veryCasual)
                    }
                }
                TextEditor(text: $ctx.instructions)
                    .font(.body)
                    .frame(minHeight: 56)
                    .scrollContentBackground(.hidden)
            }
            .padding(6)
        }
    }

    private func presetButton(_ label: String, _ text: String) -> some View {
        Button(label) { ctx.instructions = text }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Replace the tone instructions with the \(label) preset")
    }
}

enum StylePresets {
    static let formal = "Full sentences with proper capitalization and punctuation. Professional and polished, but still human. No slang, no emojis."
    static let casual = "Relaxed and friendly, like talking to someone you know. Contractions are fine. Normal capitalization, lighter punctuation. Keep it brief."
    static let veryCasual = "lowercase, minimal punctuation, texting style. short and loose. no formal phrasing. emojis only if dictated."
}
