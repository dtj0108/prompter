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
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompts").font(.largeTitle.bold())
                    Text("How much help you want turning what you say into a prompt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
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
                    .clickCursor()
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LevelCard: View {
    let level: PromptAssistLevel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(level.label)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }

                Text(level.summary)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        selected ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.18),
                        lineWidth: selected ? 3 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .clickCursor()
    }
}
