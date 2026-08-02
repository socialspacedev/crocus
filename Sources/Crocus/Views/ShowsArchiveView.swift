import SwiftUI

/// Browse and reopen previous shows (title, number, date, theme, track count).
struct ShowsArchiveView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var shows: [AppState.ShowSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Previous Shows")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider().overlay(Theme.hairline)

            if shows.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No saved shows yet")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(shows) { s in
                            Button {
                                app.loadShow(s)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(s.name) #\(s.number)")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        HStack(spacing: 8) {
                                            Text(dateText(s.date))
                                            if !s.theme.isEmpty {
                                                Text("· \(s.theme)").foregroundStyle(Theme.accent)
                                            }
                                        }
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    Text("\(s.trackCount) songs")
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.textTertiary)
                                    if s.id == app.show.id {
                                        Text("OPEN")
                                            .font(Theme.label(9)).tracking(1)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(12)
                                .cardSurface(Theme.surface)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 460, height: 520)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .onAppear { shows = app.listShows() }
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }
}
