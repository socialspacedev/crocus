import SwiftUI

/// The ⌘, window: who's broadcasting, and where episode pages get published.
/// Everything a new installation needs to change before its first show, in the
/// console's own palette so it doesn't read as a bolted-on preferences pane.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                group("Show") {
                    field("Show name", text: $settings.showName,
                          placeholder: "My Radio Show",
                          help: "Used for new shows. Episodes you've already saved keep the name they were saved under.")
                    field("Station", text: $settings.station,
                          placeholder: "e.g. Otago Access Radio 105.4FM",
                          help: "Appears in the website export's description line. Leave it empty and the station is left out altogether.")
                    timeZoneRow
                }

                group("Website export") {
                    Text("Only used by Export Markdown…, for publishing episode pages to a static site. If you don't publish episodes, you can ignore this section.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                    field("Schema key", text: $settings.schemaKey,
                          placeholder: "radio_show",
                          help: "The `_schema` value, and the name of the front-matter block holding the tracklist.")
                    field("Tag", text: $settings.schemaTag,
                          placeholder: "radio-show",
                          help: "Added to the post's tags alongside “music”.")
                    templateRow
                }

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text("Saved to ~/Library/Application Support/Crocus/settings.json")
                        .font(Theme.mono(10))
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 2)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .frame(width: 540, height: 480)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .cardSurface(Theme.surface)
            Text(help)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The export's whole shape is a file, not code — so the useful controls are
    /// "open it" and "put it back", not a text box in here.
    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Page template")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("The front matter Export Markdown… writes. Rewrite it to match whatever your site expects — placeholders like {{show.title}} and a {{#tracks}} block are listed at the top of the file.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Edit Template…") { openTemplate() }
                Button("Reset to Default") { confirmResetTemplate() }
            }
            .controlSize(.small)
        }
    }

    private func openTemplate() {
        _ = settings.exportTemplate()          // creates it if this is the first time
        NSWorkspace.shared.open(settings.templateURL)
    }

    private func confirmResetTemplate() {
        let a = NSAlert()
        a.messageText = "Reset the page template?"
        a.informativeText = "Your edits to export-template.md will be replaced with the one Crocus ships. This can't be undone."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        settings.resetExportTemplate()
    }

    private var timeZoneRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Time zone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            // A list rather than a text field: this is set once, and a typo in an
            // identifier would silently stamp every episode with the wrong date.
            Picker("", selection: $settings.timeZoneID) {
                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
            Text("The zone episode dates are stamped in for the website export.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
