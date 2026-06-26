import SwiftUI

/// The keyboard cheat sheet (Help → Keyboard Shortcuts). Single-key controls,
/// since the computer is dedicated to the show.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider().overlay(Theme.hairline)

            VStack(spacing: 0) {
                ForEach(Array(crocusShortcuts.enumerated()), id: \.element.id) { idx, sc in
                    HStack {
                        Text(sc.action)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(sc.keys)
                            .font(Theme.mono(13, .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    if idx < crocusShortcuts.count - 1 {
                        Divider().overlay(Theme.hairline).padding(.leading, 20)
                    }
                }
            }
            .padding(.vertical, 6)

            Text("Single keys work any time the window is focused — except while typing in a text field.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(20)
        }
        .frame(width: 420)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
    }
}
