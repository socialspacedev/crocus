import Foundation

/// A single audio file in the library or a show group.
struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var artist: String
    var album: String = ""
    var year: Int? = nil
    /// Host's note about the song — maps to the website's `tracks[].note`.
    var note: String = ""
    /// Full, untrimmed duration of the file in seconds.
    var duration: TimeInterval
    /// Seconds to skip at the start of the file.
    var trimStart: TimeInterval = 0
    /// Absolute time (in seconds from file start) to stop at. `nil` = play to the end.
    var trimEnd: TimeInterval? = nil

    /// How long this track actually plays, given its trim points.
    var effectiveDuration: TimeInterval {
        max(0, (trimEnd ?? duration) - trimStart)
    }

    var displayArtistTitle: String {
        artist.isEmpty ? title : "\(artist) — \(title)"
    }
}

/// An ordered set of 2–3 songs that crossfade into each other, after which
/// the music stops so the host can back-announce.
struct SongGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New Group"
    var tracks: [Track] = []

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.effectiveDuration }
    }
}

/// One episode's plan: identity plus the ordered list of groups (the rundown).
struct Show: Codable, Identifiable {
    var id = UUID()
    var name: String = "A Certain Sound"
    var number: Int = 1
    var date: Date = Date()
    /// Episode theme, e.g. "Instrumentals", "Punk", "Covers".
    var theme: String = ""
    var groups: [SongGroup] = []

    // Playback settings, saved with the show.
    var crossfadeDuration: TimeInterval = 3
    /// How long to take ducking the music down under a voiceover.
    var duckTime: TimeInterval = 8
    /// Level the music sits at under a voiceover (0–1). ~0.45 = clearly audible bed.
    var duckLevel: Double = 0.45

    var displayTitle: String { "\(name) #\(number)" }

    /// Sum of every group's playtime, using each song's trimmed length.
    var totalPlaytime: TimeInterval { groups.reduce(0) { $0 + $1.totalDuration } }

    /// Total number of songs across all groups in the rundown.
    var trackCount: Int { groups.reduce(0) { $0 + $1.tracks.count } }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - Tolerant decoding
//
// Declaring `init(from:)` in an *extension* keeps the synthesized memberwise
// initializer, while `decodeIfPresent` lets old saves (and future schema
// changes) load without throwing on missing keys.

extension Track {
    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, album, year, note, duration, trimStart, trimEnd
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let u = try c.decode(URL.self, forKey: .url)
        url = u
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? u.deletingPathExtension().lastPathComponent
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
    }
}

extension SongGroup {
    enum CodingKeys: String, CodingKey { case id, name, tracks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    }
}

extension Show {
    enum CodingKeys: String, CodingKey {
        case id, name, number, date, theme, groups, crossfadeDuration, duckTime, duckLevel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "A Certain Sound"
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? ""
        groups = try c.decodeIfPresent([SongGroup].self, forKey: .groups) ?? []
        crossfadeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .crossfadeDuration) ?? 3
        duckTime = try c.decodeIfPresent(TimeInterval.self, forKey: .duckTime) ?? 8
        duckLevel = try c.decodeIfPresent(Double.self, forKey: .duckLevel) ?? 0.45
    }
}

/// Points at a specific track inside a specific group (for trim/note edits and
/// the waveform panel).
struct TrackRef: Hashable {
    var groupID: SongGroup.ID
    var trackID: Track.ID
}

// MARK: - Time formatting helpers

enum TimeFmt {
    /// "3:07" style.
    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "-0:42" style countdown.
    static func countdown(_ t: TimeInterval) -> String {
        "-" + clock(max(0, t))
    }
}
