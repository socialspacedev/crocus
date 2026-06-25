import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ShowHeaderView()
                Divider().overlay(Theme.hairline)

                NowPlayingView()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider().overlay(Theme.hairline)

                HStack(spacing: 0) {
                    LibraryView()
                        .frame(width: 320)
                    Divider().overlay(Theme.hairline)
                    RundownView()
                        .frame(maxWidth: .infinity)
                }

                Divider().overlay(Theme.hairline)
                TransportView()
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .fileImporter(
            isPresented: $app.showImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { app.importItems(urls) }
        }
    }
}

/// Editable show identity: "A Certain Sound  #1  ·  June 20, 2026".
struct ShowHeaderView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 14) {
            TextField("Show name", text: $app.show.name)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: 240)
                .onSubmit { app.saveShow() }

            HStack(spacing: 4) {
                Text("#").foregroundStyle(Theme.textTertiary)
                TextField("1", value: $app.show.number, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 36)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .onSubmit { app.saveShow() }
            }

            Text("·").foregroundStyle(Theme.textTertiary)

            DatePicker("", selection: $app.show.date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .onChange(of: app.show.date) { _, _ in app.saveShow() }

            Spacer()

            Button {
                app.newShow()
            } label: {
                Label("New Show", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
