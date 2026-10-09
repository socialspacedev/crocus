import Foundation

/// The Markdown export's shape, as a template the user owns rather than code.
///
/// *Export Markdown…* writes a page for a static site, and every site wants
/// different front matter — different field names, a different layout, fields
/// Crocus has never heard of. Rather than guess, Crocus renders a template file
/// you can rewrite to match whatever your site expects.
///
/// The engine is deliberately tiny and line-oriented, because YAML front matter
/// is line-oriented. Three rules, and that's the whole language:
///
///   `{{token}}`                 replaced by its value
///   `{{token|yaml}}`            same, but quoted if YAML would need it
///   `{{#tracks}}` … `{{/tracks}}`  the lines between are repeated per song
///
/// plus one convenience that removes the need for conditionals entirely:
/// **a line whose placeholders all come out empty is dropped.** So a template
/// line of `year: {{track.year}}` simply disappears for a song with no year,
/// the way hand-written front matter would.
enum ExportTemplate {

    /// Shipped default. Targets a CloudCannon/Eleventy episode page — which is
    /// what it was grown from — but every site-specific thing in it is a line
    /// somebody else can change.
    static let standard = """
    {{! ------------------------------------------------------------------ }}
    {{! Crocus page template — Export Markdown… renders this.               }}
    {{! Rewrite it to match whatever your site expects.                     }}
    {{!                                                                     }}
    {{!   {{token}}        replaced by its value                            }}
    {{!   {{token|yaml}}   same, quoted if YAML needs it                    }}
    {{!   {{#tracks}}…{{/tracks}}   lines between are repeated per song      }}
    {{!   {{! … }}         a note to yourself; never reaches the output     }}
    {{!                                                                     }}
    {{! A line whose placeholders all come out empty is left out — which is }}
    {{! why "year:" below simply vanishes for a song with no year.          }}
    {{!                                                                     }}
    {{! Show:  {{show.name}} {{show.number}} {{show.title}} {{show.theme}}  }}
    {{!        {{show.description}} {{show.date}} {{show.dateLong}}         }}
    {{!        {{show.slug}} {{show.trackCount}} {{show.playtime}}          }}
    {{! Also:  {{station}} {{schemaKey}} {{schemaTag}}                      }}
    {{! Song:  {{track.n}} {{track.artist}} {{track.title}} {{track.year}}  }}
    {{!        {{track.note}} {{track.album}} {{track.group}}               }}
    {{! ------------------------------------------------------------------ }}
    ---
    _schema: {{schemaKey}}
    title: {{show.title|yaml}}
    description: {{show.description|yaml}}
    date: {{show.date}}
    type: article
    layout: article.liquid
    tags:
      - music
      - {{schemaTag}}
    {{schemaKey}}:
      hero_image:
      hero_alt:
      hero_caption:
      oar_url:
      tracks:
    {{#tracks}}
        - artist: {{track.artist|yaml}}
          title: {{track.title|yaml}}
          year: {{track.year}}
          note: {{track.note|yaml}}
    {{/tracks}}
    ---

    """

    /// Every token a template can use, for the Settings window and the README.
    static let tokens: [(String, String)] = [
        ("{{show.name}}", "Show name, from Settings"),
        ("{{show.number}}", "Episode number"),
        ("{{show.title}}", "“<name> (Episode <n>)”"),
        ("{{show.theme}}", "Episode theme, if set"),
        ("{{show.description}}", "“Theme: … Originally broadcast on … on <station>.”"),
        ("{{show.date}}", "ISO 8601, in the Settings time zone"),
        ("{{show.dateLong}}", "e.g. “October 9, 2026”"),
        ("{{show.slug}}", "URL-safe name, e.g. certain-sound-episode-5"),
        ("{{show.trackCount}}", "Number of songs in the rundown"),
        ("{{show.playtime}}", "Total playtime, m:ss"),
        ("{{station}}", "Station, from Settings"),
        ("{{schemaKey}}", "Schema key, from Settings"),
        ("{{schemaTag}}", "Tag, from Settings"),
        ("{{track.n}}", "Position in the show, 1-based (inside {{#tracks}})"),
        ("{{track.artist}}", "Artist"),
        ("{{track.title}}", "Song title"),
        ("{{track.year}}", "Year, if known"),
        ("{{track.note}}", "Your note on the song"),
        ("{{track.album}}", "Album, if known"),
        ("{{track.group}}", "Which group of the rundown it played in"),
    ]

    // MARK: - Rendering

    /// Render `template` against a set of scalar values plus one row per song.
    /// A track's own values shadow the show-level ones, so `{{track.title}}` and
    /// `{{show.title}}` can't be confused for each other.
    static func render(_ template: String,
                       values: [String: String],
                       tracks: [[String: String]]) -> String {
        var out: [String] = []
        let lines = template.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let tag = lines[i].trimmingCharacters(in: .whitespaces)
            // A comment line is for whoever edits the template, not the output —
            // which is how the file manages to document itself without the notes
            // ending up in the front matter.
            if tag.hasPrefix("{{!") {
                i += 1
                continue
            }
            if tag == "{{#tracks}}" {
                var body: [String] = []
                i += 1
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces) != "{{/tracks}}" {
                    body.append(lines[i])
                    i += 1
                }
                i += 1                                  // step over {{/tracks}}
                for track in tracks {
                    let scope = values.merging(track) { _, trackValue in trackValue }
                    for line in body {
                        if let rendered = renderLine(line, scope) { out.append(rendered) }
                    }
                }
                continue
            }
            if let rendered = renderLine(lines[i], values) { out.append(rendered) }
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// One line, or nil if the line should be left out altogether.
    private static func renderLine(_ line: String, _ values: [String: String]) -> String? {
        guard line.contains("{{") else { return line }
        var out = ""
        var rest = Substring(line)
        var sawPlaceholder = false
        var sawValue = false

        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                // Unclosed braces: leave the rest exactly as written rather than
                // swallowing it, so a typo in a template is visible in the output.
                out += rest[open.lowerBound...]
                return out
            }
            let tag = rest[open.upperBound..<close.lowerBound]
            let parts = tag.split(separator: "|", maxSplits: 1)
                           .map { $0.trimmingCharacters(in: .whitespaces) }
            sawPlaceholder = true
            var value = values[parts[0]] ?? ""
            if !value.isEmpty {
                sawValue = true
                if parts.count > 1, parts[1] == "yaml" { value = yamlScalar(value) }
            }
            out += value
            rest = rest[close.upperBound...]
        }
        out += rest

        // Nothing but empty placeholders — the line has nothing left to say.
        if sawPlaceholder && !sawValue { return nil }
        return out
    }

    /// A YAML scalar, quoted only when it has to be.
    static func yamlScalar(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuote = s.contains(where: { ":#{}[],&*!|>'\"%@`".contains($0) })
            || s.first == " " || s.last == " "
            || ["true", "false", "yes", "no", "null"].contains(s.lowercased())
        guard needsQuote else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
