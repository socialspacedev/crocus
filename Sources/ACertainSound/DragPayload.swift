import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let crocusTrack = UTType(exportedAs: "com.andrewlong.crocus.track")
    static let crocusGroup = UTType(exportedAs: "com.andrewlong.crocus.group")
}

/// Carried when dragging a whole group to reorder the rundown.
struct GroupDragPayload: Codable, Transferable {
    var groupID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .crocusGroup)
    }
}

/// What gets carried during a drag: the track's id and where it came from.
/// `fromGroupID == nil && !fromBackups` = the library; `fromBackups` = the
/// Backups shelf.
struct DragPayload: Codable, Transferable {
    var trackID: UUID
    var fromGroupID: UUID?
    var fromBackups: Bool = false

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .crocusTrack)
    }
}
