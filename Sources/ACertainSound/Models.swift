import Foundation

/// A single audio file in the library or a show group.
struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var artist: String
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
struct Show: Codable {
    var name: String = "A Certain Sound"
    var number: Int = 1
    var date: Date = Date()
    var groups: [SongGroup] = []

    // Playback settings, saved with the show.
    var crossfadeDuration: TimeInterval = 3
    var fadeToTalkDuration: TimeInterval = 45

    var displayTitle: String { "\(name) #\(number)" }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }
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
