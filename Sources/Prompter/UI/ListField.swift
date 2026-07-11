import SwiftUI

/// A text field for editing a [String] as comma-separated text.
/// Edits a local buffer and commits on submit/blur — a live-normalizing binding
/// would strip the comma the moment you type it, making a second item untypeable.
struct ListField: View {
    let placeholder: String
    @Binding var list: [String]
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = list.joined(separator: ", ") }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: list) { _, newValue in
                if !focused { text = newValue.joined(separator: ", ") }
            }
    }

    private func commit() {
        list = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
