import SwiftUI

/// Edit a library song's metadata. Two layers:
///   • the fields Crocus shows / exports (always editable), and
///   • the tags actually embedded in the file (shown for reference, and — for
///     mp3 / m4a — writable back into the file so Music, Finder, etc. agree).
struct MetadataEditorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let track: Track

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var yearText = ""

    @State private var fileTags: FileTags?
    @State private var loadingFile = true

    private enum WriteState: Equatable {
        case idle, writing, wrote, failed(String)
    }
    @State private var writeState: WriteState = .idle

    private var year: Int? {
        let t = yearText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Int(t)
    }
    private var writability: TagWritability { MetadataIO.writability(for: track.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editSection
                    fileSection
                }
                .padding(20)
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 640)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            title = track.title
            artist = track.artist
            album = track.album
            yearText = track.year.map(String.init) ?? ""
            loadFileTags()
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            Text("Edit Info")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            statusView
            Spacer()
            Button("Save in Crocus") {
                app.updateTrackMetadata(id: track.id, title: title, artist: artist,
                                        album: album, year: year)
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)

            Button {
                writeToFile()
            } label: {
                Text(writeState == .writing ? "Writing…" : "Write to File")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(writability.canWrite ? Theme.background : Theme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(writability.canWrite ? Theme.accent : Theme.surfaceHi,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!writability.canWrite || writeState == .writing)
            .help(writability.canWrite
                  ? "Write these tags into the audio file"
                  : MetadataIO.unsupportedReason(for: track.url))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var statusView: some View {
        switch writeState {
        case .idle, .writing:
            EmptyView()
        case .wrote:
            Label("Written to file", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: Edit fields

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Details")
            field("Title", text: $title)
            field("Artist", text: $artist)
            field("Album", text: $album)
            field("Year", text: $yearText, width: 90)
        }
    }

    private func field(_ label: String, text: Binding<String>, width: CGFloat? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: width, alignment: .leading)
                .cardSurface(Theme.surface)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
    }

    // MARK: Embedded-file tags

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("In the File")
                Spacer()
                if hasFileValues {
                    Button("Use file values") { adoptFileValues() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }

            if loadingFile {
                Text("Reading tags…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else if let f = fileTags {
                VStack(alignment: .leading, spacing: 6) {
                    fileRow("Title", f.title, current: title)
                    fileRow("Artist", f.artist, current: artist)
                    fileRow("Album", f.album, current: album)
                    fileRow("Year", f.year.map(String.init), current: yearText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(Theme.surface)
            }

            if !writability.canWrite {
                Text(MetadataIO.unsupportedReason(for: track.url))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func fileRow(_ label: String, _ value: String?, current: String) -> some View {
        let shown = (value?.isEmpty == false) ? value! : "—"
        let differs = (value?.isEmpty == false) && value != current
        return HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(shown)
                .font(.system(size: 13))
                .foregroundStyle(differs ? Theme.accent : Theme.textSecondary)
                .lineLimit(1)
            if differs {
                Text("differs")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.accentSoft, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    private var hasFileValues: Bool {
        guard let f = fileTags else { return false }
        return f.title?.isEmpty == false || f.artist?.isEmpty == false
            || f.album?.isEmpty == false || f.year != nil
    }

    private func adoptFileValues() {
        guard let f = fileTags else { return }
        if let t = f.title, !t.isEmpty { title = t }
        if let a = f.artist, !a.isEmpty { artist = a }
        if let al = f.album, !al.isEmpty { album = al }
        if let y = f.year { yearText = String(y) }
    }

    private func loadFileTags() {
        loadingFile = true
        let url = track.url
        Task {
            let tags = await MetadataIO.readFileTags(url)
            fileTags = tags
            loadingFile = false
        }
    }

    private func writeToFile() {
        writeState = .writing
        Task {
            do {
                try await app.writeTagsToFile(id: track.id, title: title, artist: artist,
                                              album: album, year: year)
                writeState = .wrote
                loadFileTags() // reflect what's now on disk
            } catch {
                writeState = .failed(error.localizedDescription)
            }
        }
    }
}
