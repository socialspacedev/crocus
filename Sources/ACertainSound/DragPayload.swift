import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let crocusTrack = UTType(exportedAs: "com.andrewlong.crocus.track")
}

/// What gets carried during a drag: the track's id and where it came from
/// (`nil` group = dragged out of the library).
struct DragPayload: Codable, Transferable {
    var trackID: UUID
    var fromGroupID: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .crocusTrack)
    }
}
