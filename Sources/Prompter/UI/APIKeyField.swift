import AppKit
import SwiftUI

/// A full-width API key box shared by Settings → API Keys and the setup step:
/// show/hide, paste, and a Test button that proves the key works for real.
struct APIKeyField: View {
    let title: String
    let placeholder: String
    @Binding var key: String
    let provider: APIKeyProvider
    var required = false
    @ObservedObject private var verifier = APIKeyVerifier.shared
    @State private var revealed = false

    private var status: APIKeyVerifier.Status { verifier.status(provider) }
    private var isEmpty: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AmbitiousDesign.text)
                Text(required ? "Required" : "Optional")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(required ? AmbitiousDesign.brandPrimary : AmbitiousDesign.textTertiary)
                Spacer()
                statusLabel
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Group {
                        if revealed {
                            TextField(placeholder, text: $key)
                        } else {
                            SecureField(placeholder, text: $key)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { if !isEmpty { verifier.check(provider) } }

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(AmbitiousDesign.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(revealed ? "Hide key" : "Show key")
                    .clickCursor()
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(AmbitiousDesign.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1))

                Button("Paste") {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        verifier.check(provider)
                    }
                }
                .buttonStyle(AmbitiousSecondaryButtonStyle(compact: true))
                .clickCursor()

                Button(status == .checking ? "Testing…" : "Test") { verifier.check(provider) }
                    .buttonStyle(AmbitiousPrimaryButtonStyle(compact: true))
                    .disabled(isEmpty || status == .checking)
                    .clickCursor()
            }

            if case .failed(let message) = status {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(AmbitiousDesign.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: key) { verifier.refresh(provider) }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .missing:
            EmptyView()
        case .untested:
            Text("Not tested yet")
                .font(.system(size: 12))
                .foregroundStyle(AmbitiousDesign.textTertiary)
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Testing…").font(.system(size: 12)).foregroundStyle(AmbitiousDesign.textSecondary)
            }
        case .verified:
            Label("Working", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.success)
        case .failed:
            Label("Not working", systemImage: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.error)
        }
    }

    private var borderColor: Color {
        switch status {
        case .verified: return AmbitiousDesign.success.opacity(0.7)
        case .failed: return AmbitiousDesign.error.opacity(0.7)
        default: return AmbitiousDesign.borderStrong
        }
    }
}
