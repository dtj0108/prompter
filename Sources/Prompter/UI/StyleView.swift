import AppKit
import SwiftUI

struct StyleView: View {
    @EnvironmentObject var store: StyleStore
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var activeApp = ActiveAppMonitor.shared
    @State private var selectedContextId = "personal"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                contextTabs

                if let index = selectedContextIndex {
                    ContextStylePage(
                        context: $store.style.contexts[index],
                        activeAppName: activeApp.appName,
                        activeBundleId: activeApp.bundleId,
                        onAssignActiveApp: { assignActiveApp(to: selectedContextId) },
                        onDelete: { deleteSelectedContext() }
                    )
                }

                thoughtSeparationToggle
                globalVoiceEditor
                promptModeEditor
            }
            .padding(24)
        }
        .onAppear { ensureValidSelection() }
        .onChange(of: store.style.contexts.map(\.id)) { _, _ in ensureValidSelection() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Style").font(.largeTitle.bold())
                Text("Choose how Prompter writes in each kind of app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !activeApp.bundleId.isEmpty {
                Menu {
                    ForEach(store.style.contexts) { context in
                        Button {
                            assignActiveApp(to: context.id)
                            selectedContextId = context.id
                        } label: {
                            if activeContextId == context.id {
                                Label(context.name, systemImage: "checkmark")
                            } else {
                                Text(context.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "scope")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(activeApp.appName)
                                .font(.caption.weight(.semibold))
                            Text(activeContextName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
                .menuStyle(.borderlessButton)
                .help("Assign the active app to a writing style")
            }
        }
    }

    private var contextTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(store.style.contexts) { context in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { selectedContextId = context.id }
                    } label: {
                        VStack(spacing: 9) {
                            Text(context.name)
                                .font(.callout.weight(selectedContextId == context.id ? .semibold : .medium))
                                .foregroundStyle(selectedContextId == context.id ? .primary : .secondary)
                            Rectangle()
                                .fill(selectedContextId == context.id ? Color.primary : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Button { addContext() } label: {
                    Label("New", systemImage: "plus")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 11)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
        }
    }

    private var thoughtSeparationToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.append")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("I like to separate my sentences and thoughts").font(.body.weight(.semibold))
                Text("Groups what you say into a couple of sentences at a time, starting a new line whenever a new thought begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Separate thoughts", isOn: $config.config.separateThoughts)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private var globalVoiceEditor: some View {
        DisclosureGroup("Your voice — applies everywhere") {
            TextEditor(text: $store.style.globalVoice)
                .font(.body)
                .frame(minHeight: 70)
                .padding(6)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .scrollContentBackground(.hidden)
                .padding(.top, 8)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private var promptModeEditor: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt Mode").font(.body.weight(.semibold))
                Text("Uses separate coding-specialized rules to turn rough ideas into high-quality prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit instructions…") {
                Prompts.ensurePromptModeFileExists()
                NSWorkspace.shared.open(Paths.promptModeFile)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedContextIndex: Int? {
        store.style.contexts.firstIndex(where: { $0.id == selectedContextId })
    }

    private var activeContextId: String {
        guard !activeApp.bundleId.isEmpty else { return "other" }
        return ContextDetector.match(
            bundleId: activeApp.bundleId,
            title: "",
            contexts: store.style.contexts
        )?.id ?? "other"
    }

    private var activeContextName: String {
        store.style.contexts.first(where: { $0.id == activeContextId })?.name ?? "Everything else"
    }

    private func assignActiveApp(to contextId: String) {
        let bundleId = activeApp.bundleId
        guard !bundleId.isEmpty else { return }
        for index in store.style.contexts.indices {
            store.style.contexts[index].appBundleIds.removeAll {
                $0.caseInsensitiveCompare(bundleId) == .orderedSame
            }
        }
        guard contextId != "other",
              let index = store.style.contexts.firstIndex(where: { $0.id == contextId }) else { return }
        store.style.contexts[index].appBundleIds.append(bundleId)
    }

    private func addContext() {
        let context = ContextStyle(
            id: "custom-\(UUID().uuidString.prefix(6).lowercased())",
            name: "New context",
            appBundleIds: [],
            titleKeywords: [],
            instructions: StylePresets.casual,
            tonePreset: TonePreset.casual.rawValue
        )
        let index = store.style.contexts.firstIndex(where: { $0.id == "other" }) ?? store.style.contexts.endIndex
        store.style.contexts.insert(context, at: index)
        selectedContextId = context.id
    }

    private func deleteSelectedContext() {
        guard selectedContextId != "other" else { return }
        store.style.contexts.removeAll { $0.id == selectedContextId }
        selectedContextId = store.style.contexts.first?.id ?? "other"
    }

    private func ensureValidSelection() {
        if selectedContextIndex == nil {
            selectedContextId = store.style.contexts.first?.id ?? "other"
        }
    }
}

private struct ContextStylePage: View {
    @Binding var context: ContextStyle
    let activeAppName: String
    let activeBundleId: String
    let onAssignActiveApp: () -> Void
    let onDelete: () -> Void

    private var presets: [TonePreset] {
        context.id == "ai" ? [.aiAssist, .formal, .casual] : [.formal, .casual, .veryCasual]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContextBanner(
                context: context,
                activeAppName: activeAppName,
                activeBundleId: activeBundleId,
                onAssignActiveApp: onAssignActiveApp
            )

            if context.tonePreset == nil {
                Label("Custom instructions are active", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                ForEach(presets) { preset in
                    ToneCard(
                        preset: preset,
                        selected: context.tonePreset == preset.rawValue,
                        contextId: context.id
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            context.tonePreset = preset.rawValue
                            context.instructions = preset.instructions
                        }
                    }
                }
            }

            advancedEditor
        }
    }

    private var advancedEditor: some View {
        DisclosureGroup("Customize apps and instructions") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Context name", text: $context.name)
                    .textFieldStyle(.roundedBorder)

                if context.id != "other" {
                    LabeledContent("Apps (bundle IDs)") {
                        ListField(placeholder: "com.example.app, …", list: $context.appBundleIds)
                    }
                    LabeledContent("Browser title keywords") {
                        ListField(placeholder: "gmail, inbox, …", list: $context.titleKeywords)
                    }
                }

                Text("Detailed instructions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: customInstructionsBinding)
                    .font(.body)
                    .frame(minHeight: 76)
                    .padding(6)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .scrollContentBackground(.hidden)

                if context.id != "other" {
                    Button("Delete this context", role: .destructive, action: onDelete)
                        .controlSize(.small)
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private var customInstructionsBinding: Binding<String> {
        Binding(
            get: { context.instructions },
            set: {
                context.instructions = $0
                context.tonePreset = nil
            }
        )
    }
}

private struct ContextBanner: View {
    let context: ContextStyle
    let activeAppName: String
    let activeBundleId: String
    let onAssignActiveApp: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 25, weight: .medium, design: .serif))
                    .foregroundStyle(.white)
                Text("Prompter recognizes the active app and applies this style before pasting at your cursor.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: -8) {
                ForEach(Array(context.appBundleIds.prefix(4)), id: \.self) { bundleId in
                    AppIconChip(bundleId: bundleId)
                }
                if !activeBundleId.isEmpty && !containsActiveApp {
                    Button(action: onAssignActiveApp) {
                        ZStack {
                            Circle().fill(.white.opacity(0.14))
                            Image(systemName: "plus")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(width: 48, height: 48)
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Add \(activeAppName) to \(context.name)")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, minHeight: 142)
        .background(bannerGradient, in: RoundedRectangle(cornerRadius: 18))
    }

    private var title: String {
        switch context.id {
        case "personal": return "This style applies in personal messages"
        case "work": return "This style applies in work apps"
        case "email": return "This style applies in email"
        case "ai": return "This style applies in AI apps"
        case "other": return "This style applies everywhere else"
        default: return "This style applies in \(context.name.lowercased())"
        }
    }

    private var containsActiveApp: Bool {
        context.appBundleIds.contains { $0.caseInsensitiveCompare(activeBundleId) == .orderedSame }
    }

    private var bannerGradient: LinearGradient {
        let colors: [Color]
        switch context.id {
        case "personal": colors = [Color(red: 0.10, green: 0.30, blue: 0.38), .brown.opacity(0.85), Color(red: 0.20, green: 0.31, blue: 0.22)]
        case "work": colors = [Color(red: 0.12, green: 0.22, blue: 0.42), Color(red: 0.24, green: 0.17, blue: 0.38), Color(red: 0.12, green: 0.32, blue: 0.38)]
        case "email": colors = [Color(red: 0.37, green: 0.13, blue: 0.18), Color(red: 0.20, green: 0.18, blue: 0.30), Color(red: 0.15, green: 0.30, blue: 0.42)]
        case "ai": colors = [Color(red: 0.23, green: 0.12, blue: 0.43), Color(red: 0.39, green: 0.17, blue: 0.49), Color(red: 0.10, green: 0.33, blue: 0.42)]
        default: colors = [Color(red: 0.20, green: 0.23, blue: 0.29), Color(red: 0.29, green: 0.24, blue: 0.34), Color(red: 0.20, green: 0.29, blue: 0.31)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

private struct AppIconChip: View {
    let bundleId: String

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.18))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "app.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .frame(width: 48, height: 48)
        .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 1))
    }

    private var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct ToneCard: View {
    let preset: TonePreset
    let selected: Bool
    let contextId: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(preset.title)
                        .font(.system(size: 25, weight: .medium, design: .serif))
                        .foregroundStyle(.primary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                Text(preset.subtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                Text(preset.example(for: contextId))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.86))
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                    .padding(14)
                    .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 226, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.18), lineWidth: selected ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private enum TonePreset: String, CaseIterable, Identifiable {
    case formal
    case casual
    case veryCasual
    case aiAssist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: return "Formal."
        case .casual: return "Casual"
        case .veryCasual: return "very casual"
        case .aiAssist: return "AI assist"
        }
    }

    var subtitle: String {
        switch self {
        case .formal: return "Caps + punctuation"
        case .casual: return "Caps + lighter punctuation"
        case .veryCasual: return "No caps + less punctuation"
        case .aiAssist: return "Structured + actionable"
        }
    }

    var instructions: String {
        switch self {
        case .formal: return StylePresets.formal
        case .casual: return StylePresets.casual
        case .veryCasual: return StylePresets.veryCasual
        case .aiAssist: return StylePresets.aiAssist
        }
    }

    func example(for contextId: String) -> String {
        if contextId == "ai" {
            switch self {
            case .aiAssist: return "Implement the change, preserve existing behavior, and verify it with focused tests."
            case .formal: return "Please review the implementation and provide a concise assessment of the relevant risks."
            case .casual: return "Take a look at this implementation and tell me what you’d improve"
            case .veryCasual: return "look at this code and tell me what to fix"
            }
        }
        switch self {
        case .formal: return "Hey, are you free for lunch tomorrow? Let’s meet at 12 if that works for you."
        case .casual: return "Hey are you free for lunch tomorrow? Let’s do 12 if that works for you"
        case .veryCasual: return "hey are you free for lunch tomorrow? lets do 12 if that works"
        case .aiAssist: return "Share the goal, relevant context, constraints, and desired result."
        }
    }
}

enum StylePresets {
    static let formal = "Full sentences with proper capitalization and punctuation. Professional and polished, but still human. No slang, no emojis."
    static let casual = "Relaxed and friendly, like talking to someone you know. Contractions are fine. Normal capitalization, lighter punctuation. Keep it brief."
    static let veryCasual = "lowercase, minimal punctuation, texting style. short and loose. no formal phrasing. emojis only if dictated."
    static let aiAssist = "Structure the request so an AI can act on it. Lead with the objective, preserve all context and constraints, and organize multi-part requests clearly. Do not answer the request or invent requirements."
}
