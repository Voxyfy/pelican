import SwiftUI

/// Main window, laid out like Transmit: this Mac on the left, a server on the right.
struct BrowserWindow: View {
    @State private var connection = Connection()
    @State private var localPane: PaneModel?
    @State private var search = ""
    @State private var tab: RemoteSide.Tab = .quickConnect
    @State private var showHostKeyAlert = false
    @State private var queue = TransferQueue()
    @State private var conflict: Conflict?

    /// A transfer waiting on "replace or skip?" because some names already exist at the destination.
    private struct Conflict {
        let items: [FileItem]
        let existing: [String]
        let direction: Transfer.Direction
        let folder: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                Group {
                    if let localPane {
                        PaneView(model: localPane, actions: localActions) { ShortcutBar(model: localPane) }
                    } else {
                        accessPrompt
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                RemoteSide(connection: connection, actions: remoteActions, copyWithin: copyOnServer,
                           search: search, tab: $tab)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                ActivityButton(queue: queue, log: ActivityLog.shared)
            }
        }
        .alert(conflictTitle, isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { pending in
            Button(String(localized: "Replace")) { start(pending.items, pending.direction, into: pending.folder) }
            if pending.existing.count < pending.items.count {
                Button(String(localized: "Skip Existing")) {
                    start(pending.items.filter { !pending.existing.contains($0.name) }, pending.direction,
                          into: pending.folder)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { pending in
            Text(pending.existing.prefix(5).joined(separator: ", ") + (pending.existing.count > 5 ? "…" : ""))
        }
        .navigationTitle("Pelican — \(windowSubtitle)")
        .searchable(text: $search, placement: .toolbar, prompt: Text(String(localized: "Search Servers")))
        .onChange(of: search) { _, text in
            if !text.isEmpty { tab = .servers }
        }
        .alert(hostKeyTitle, isPresented: $showHostKeyAlert) {
            Button(hostKeyChanged ? String(localized: "Trust New Key") : String(localized: "Trust and Connect"),
                   role: hostKeyChanged ? .destructive : nil) {
                Task { await connection.trustPending() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                connection.hostKeyPrompt = nil
            }
        } message: {
            if let prompt = connection.hostKeyPrompt {
                Text("\(prompt.error.localizedDescription)\n\n\(HostKeys.fingerprint(prompt.error.presentedKey))")
            }
        }
        .onChange(of: connection.hostKeyPrompt != nil) { _, pending in
            if pending { showHostKeyAlert = true }
        }
        .onAppear {
            if !connection.favorites.servers.isEmpty { tab = .servers }
            if localPane == nil, let url = FolderAccess.restore() {
                localPane = PaneModel(source: LocalFileSource(root: url))
            }
        }
    }

    /// What the right pane shows: the connected server, or the open tab.
    private var windowSubtitle: String {
        if let server = connection.server { return server.title }
        switch tab {
        case .servers: return String(localized: "Servers")
        case .quickConnect: return String(localized: "Quick Connect")
        }
    }

    // MARK: Transfers

    private var conflictTitle: String {
        guard let conflict else { return "" }
        return conflict.existing.count == 1
            ? String(localized: "“\(conflict.existing[0])” already exists. Replace it?")
            : String(localized: "\(conflict.existing.count) items already exist. Replace them?")
    }

    private var localActions: PaneActions? {
        guard let server = connection.server else { return nil }
        return PaneActions(
            sendTitle: String(localized: "Upload to \(server.title)"),
            send: { transfer($0, .upload) },
            receive: { drop, folder in
                guard case .rows(let drag) = drop, drag.paneID == connection.pane?.id else { return }
                transfer(drag.paths.compactMap { connection.pane?.item(withID: $0) }, .download, into: folder)
            }
        )
    }

    private var remoteActions: PaneActions? {
        guard let localPane else { return nil }
        return PaneActions(
            sendTitle: String(localized: "Download to This Mac"),
            send: { transfer($0, .download) },
            receive: { drop, folder in
                switch drop {
                case .rows(let drag) where drag.paneID == localPane.id:
                    transfer(drag.paths.compactMap { localPane.item(withID: $0) }, .upload, into: folder)
                case .files(let urls):
                    transfer(urls.compactMap(FileItem.init(localURL:)), .upload, into: folder)
                default:
                    break
                }
            }
        )
    }

    /// Asks before replacing anything with the same name, then queues the transfer.
    /// Without a folder, items go to the folder the other pane is showing.
    private func transfer(_ items: [FileItem], _ direction: Transfer.Direction, into folder: String? = nil) {
        guard !items.isEmpty, let destination = direction == .upload ? connection.pane : localPane else { return }
        let target = folder ?? destination.path
        let existing = items.map(\.name).filter(destination.names(in: target).contains)
        if existing.isEmpty {
            start(items, direction, into: target)
        } else {
            conflict = Conflict(items: items, existing: existing, direction: direction, folder: target)
        }
    }

    private func start(_ items: [FileItem], _ direction: Transfer.Direction, into folder: String) {
        guard !items.isEmpty, let remote = connection.pane, let server = remote.source as? any RemoteSource,
              let localPane else { return }
        switch direction {
        case .upload:
            queue.upload(items, to: folder, via: server) { Task { await remote.refresh(folder) } }
        case .download:
            queue.download(items, to: folder, via: server) { Task { await localPane.refresh(folder) } }
        case .copy:
            copyOnServer(items, folder)
        }
    }

    /// ⌥-drag inside the server pane: copies through this Mac, renaming if the name is taken.
    private func copyOnServer(_ items: [FileItem], _ folder: String) {
        guard let remote = connection.pane, let server = remote.source as? any RemoteSource else { return }
        let named = items
            .filter { folder != $0.path && !folder.hasPrefix($0.path + "/") }
            .map { ($0, remote.freeName(for: $0.name, in: folder, copy: true)) }
        guard !named.isEmpty else { return }
        queue.copy(named, to: folder, via: server) { Task { await remote.reloadAll() } }
    }

    private var hostKeyChanged: Bool { connection.hostKeyPrompt?.error.changed == true }

    private var hostKeyTitle: String {
        hostKeyChanged
            ? String(localized: "Server Identity Changed")
            : String(localized: "Trust This Server?")
    }

    private var accessPrompt: some View {
        ContentUnavailableView {
            Label(String(localized: "This Mac"), systemImage: "laptopcomputer")
        } description: {
            Text(String(localized: "Pelican needs your permission once to show the files on this Mac."))
        } actions: {
            Button(String(localized: "Choose Folder…")) {
                if let url = FolderAccess.choose() {
                    localPane = PaneModel(source: LocalFileSource(root: url))
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
