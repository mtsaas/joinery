import SwiftUI

/// The one live text field, laid over the cell being edited: it takes focus as it appears, with the caret at the end
/// or everything selected. For a type, the rest of the type the text so far would become shows faded after it
/// ("ti" → "mestamp").
struct CellEditor: View {
    @Binding var text: String
    let selectsAll: Bool
    let completesTypes: Bool
    let lostFocus: () -> Void
    @FocusState private var isFocused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        TextField("", text: $text, selection: $selection)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .overlay(alignment: .leading) {
                if completesTypes {
                    // Monospaced, so a hidden copy of the text lines the rest up exactly.
                    HStack(spacing: 0) {
                        Text(text).hidden()
                        Text(completion).foregroundStyle(.tertiary)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                placeCaret()
                isFocused = true
            }
            // Keys typed before it had focus were added to the text for it; the caret goes after them.
            .onChange(of: text) { if !isFocused { selection = TextSelection(insertionPoint: text.endIndex) } }
            .onChange(of: isFocused) {
                guard isFocused else { return lostFocus() }
                // A text field selects all its text as it takes focus, after anything set before; set it again once
                // focus has arrived, and once more after AppKit finishes, or the next key would replace the first.
                placeCaret()
                DispatchQueue.main.async { placeCaret() }
            }
    }

    /// Typing over a cell wants the caret after what was typed; a double-click, everything selected.
    private func placeCaret() {
        selection = selectsAll ? TextSelection(range: text.startIndex..<text.endIndex) : TextSelection(insertionPoint: text.endIndex)
    }

    private var completion: String {
        let word = text.lowercased()
        guard !word.isEmpty, !word.hasSuffix("?"), let parsed = DataType.parse(word), parsed.type.rawValue.hasPrefix(word) else {
            return ""
        }
        return String(parsed.type.rawValue.dropFirst(word.count))
    }
}
