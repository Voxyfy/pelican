import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let pelicanItems = UTType(exportedAs: "com.voxyfy.pelican.pane-items")
}

/// Rows dragged out of a pane. Carries paths only; the receiving side looks the items up.
struct PaneDrag: Codable, Transferable {
    let paneID: UUID
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pelicanItems)
    }
}

/// What landed on a pane: rows from the other pane, or files from Finder.
enum PaneDrop {
    case rows(PaneDrag)
    case files([URL])
}

/// One thing dropped on a table row: rows from a pane, or a file from Finder.
/// Only ever imported; the export side exists because Transferable requires it.
enum PaneDropItem: Transferable {
    case rows(PaneDrag)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (item: PaneDropItem) -> PaneDrag in
            if case .rows(let drag) = item { return drag }
            return PaneDrag(paneID: UUID(), paths: [])
        }, importing: { PaneDropItem.rows($0) })
        ProxyRepresentation(exporting: { (item: PaneDropItem) -> URL in
            if case .file(let url) = item { return url }
            return URL(filePath: "/")
        }, importing: { PaneDropItem.file($0) })
    }
}

/// How a pane hands files to the other side.
struct PaneActions {
    /// Context menu title, e.g. "Upload to Example".
    let sendTitle: String
    let send: ([FileItem]) -> Void
    /// A drop, and the folder it should land in.
    let receive: (PaneDrop, String) -> Void
}
