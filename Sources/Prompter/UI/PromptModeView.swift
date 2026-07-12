import SwiftUI
import AppKit

/// Prompt Mode tab: pick how much the AI is allowed to add when turning a
/// spoken ramble into an engineered prompt. Applies to Prompt Mode only —
/// normal dictation is untouched.
struct PromptModeView: View {
    @EnvironmentObject var config: ConfigStore

    private var selected: PromptAssistLevel {
        PromptAssistLevel(rawValue: config.config.promptAssistLevel) ?? .medium
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt Mode").font(.title2.bold())
                    Text("How much help you want turning what you say into a prompt.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    ForEach(PromptAssistLevel.allCases) { level in
                        LevelCard(level: level, selected: level == selected) {
                            config.config.promptAssistLevel = level.rawValue
                        }
                    }
                }

                Text("Every level keeps what you actually said — the levels only change how much structure and guidance gets added on top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Advanced").font(.headline)
                    Text("Prompt Mode's full instructions live in a text file you can edit. Your changes survive app updates.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Edit Prompt Mode instructions…") {
                        Prompts.ensurePromptModeFileExists()
                        NSWorkspace.shared.open(Paths.promptModeFile)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LevelCard: View {
    let level: PromptAssistLevel
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.body)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(level.label).font(.headline)
                Text(level.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(selected ? 0.12 : hovered ? 0.09 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: action)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
    }
}
