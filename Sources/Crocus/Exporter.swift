import Foundation

/// Turns a show into the formats Andrew needs: a spreadsheet-pasteable table for
/// the radio station, and Markdown matching the minicannon `a_certain_sound`
/// content schema for the website.
enum Exporter {

    /// Every track across all groups, in running order.
    static func flatTracks(_ show: Show) -> [(group: Int, pos: Int, track: Track)] {
        var rows: [(Int, Int, Track)] = []
        for (gi, group) in show.groups.enumerated() {
            for (ti, track) in group.tracks.enumerated() {
                rows.append((gi + 1, ti + 1, track))
            }
        }
        return rows
    }

    // MARK: - Station running order (clipboard)

    /// One column, numbered in running order — "1 Bilders - Strange Nights".
    /// No header row and no other columns: this gets pasted straight into the
    /// station's sheet as a single column. A plain hyphen (not the en dash used
    /// on screen) separates artist from title so the text stays ASCII.
    static func runningOrder(_ show: Show) -> String {
        flatTracks(show).enumerated().map { i, row in
            let t = row.track
            let name = t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)"
            return "\(i + 1) \(name)"
        }
        .joined(separator: "\n")
    }

    // MARK: - CSV (file export — one row per track, still columnar)

    static func csv(_ show: Show) -> String {
        let headers = ["Date", "Theme", "#", "Artist", "Song"]
        func cell(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var lines = [headers.joined(separator: ",")]
        for (i, row) in flatTracks(show).enumerated() {
            let t = row.track
            let cols = [show.formattedDate, show.theme, "\(i + 1)", t.artist, t.title]
            lines.append(cols.map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Detailed notes (raw material for writing the show up)

    /// The whole episode as plain text, grouped the way it was broadcast:
    /// identity at the top, then each group's songs with year and the host's
    /// note. Track numbers run continuously across the show so they line up
    /// with `runningOrder`. Plain text so it pastes cleanly anywhere.
    static func detailedNotes(_ show: Show) -> String {
        var out = show.displayTitle + "\n"
        if !show.theme.isEmpty { out += "Theme: \(show.theme)\n" }
        out += show.formattedDate + "\n"

        var n = 0
        for (gi, group) in show.groups.enumerated() where !group.tracks.isEmpty {
            out += "\nGroup \(gi + 1)\n"
            for t in group.tracks {
                n += 1
                var line = "  \(n). "
                line += t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)"
                if let y = t.year { line += " (\(y))" }
                out += line + "\n"
                if !t.note.isEmpty { out += "      Note: \(t.note)\n" }
            }
        }
        return out
    }

    // MARK: - Markdown (a_certain_sound schema)

    static func markdown(_ show: Show) -> String {
        var out = "---\n"
        out += "_schema: a_certain_sound\n"
        out += "title: \(yaml(show.name) ) (Episode \(show.number))\n"
        out += "description: \(yaml(descriptionLine(show)))\n"
        out += "date: \(isoDate(show.date))\n"
        out += "type: article\n"
        out += "layout: article.liquid\n"
        out += "tags:\n  - music\n  - a-certain-sound\n"
        out += "a_certain_sound:\n"
        out += "  hero_image:\n"
        out += "  hero_alt:\n"
        out += "  hero_caption:\n"
        out += "  oar_url:\n"
        out += "  tracks:\n"
        for row in flatTracks(show) {
            let t = row.track
            out += "    - artist: \(yaml(t.artist))\n"
            out += "      title: \(yaml(t.title))\n"
            if let y = t.year { out += "      year: \(y)\n" }
            if !t.note.isEmpty { out += "      note: \(yaml(t.note))\n" }
        }
        out += "---\n"
        return out
    }

    private static func descriptionLine(_ show: Show) -> String {
        var s = "Originally broadcast on \(show.formattedDate) on Otago Access Radio 105.4FM."
        if !show.theme.isEmpty { s = "Theme: \(show.theme). " + s }
        return s
    }

    static func slug(_ show: Show) -> String {
        let base = "\(show.name) episode \(show.number)"
        let lowered = base.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Helpers

    /// YAML scalar with quoting only when needed.
    private static func yaml(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuote = s.contains(where: { ":#{}[],&*!|>'\"%@`".contains($0) })
            || s.first == " " || s.last == " "
            || ["true", "false", "yes", "no", "null"].contains(s.lowercased())
        if needsQuote {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return s
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Pacific/Auckland")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }
}
