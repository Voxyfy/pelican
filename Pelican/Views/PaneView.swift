import SwiftUI
import UniformTypeIdentifiers

/// A file list with a path menu and expandable folders. Used for both local and remote panes.
struct PaneView<TopBar: View>: View {
    @Bindable var model: PaneModel
    var actions: PaneActions?
    /// Copies within a server, which has to go through the transfer queue.
    var copyWithin: (([FileItem], String) -> Void)?
    @ViewBuilder var topBar: TopBar
    @State private var pendingDelete: [FileItem]?
    @State private var newFolderName = ""
    @State private var selection = Set<PaneRow.ID>()
    /// True while a drag hovers over the pane's empty space; rows highlight themselves natively.
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            Divider()
            pathBar
            Divider()
            if let error = model.error {
                ContentUnavailableView(String(localized: "Can't Open Folder"),
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                // A separate view, so hover state up here never redraws the table mid-drag.
                FileTable(model: model, selection: $selection, actions: actions,
                          onDelete: requestDelete) { drop, folder, copy in handle(drop, folder: folder, copy: copy) }
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.pelican, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.pelicanItems, .fileURL], isTargeted: $isDropTarget) { providers in
            let dropped = DroppedProviders(providers)
            let copy = NSEvent.modifierFlags.contains(.option)
            let folder = model.path
            Task {
                if let drag = await dropped.paneDrag() {
                    handle(.rows(drag), folder: folder, copy: copy)
                } else {
                    let urls = await dropped.fileURLs()
                    if !urls.isEmpty { handle(.files(urls), folder: folder, copy: copy) }
                }
            }
            return true
        }
        .alert(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { items in
            Button(String(localized: "Delete"), role: .destructive) { Task { await model.delete(items) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "This can't be undone."))
        }
        .alert(String(localized: "New Bucket"), isPresented: $model.askingFolderName) {
            TextField(String(localized: "bucket-name"), text: $newFolderName)
            Button(String(localized: "Create")) {
                let name = newFolderName
                newFolderName = ""
                Task { await model.newFolder(named: name) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { newFolderName = "" }
        } message: {
            Text(String(localized: "Bucket names use lowercase letters, numbers and hyphens, and can't be changed later."))
        }
        .alert(String(localized: "Couldn't Complete"), isPresented: Binding(
            get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(model.operationError ?? "")
        }
        .task { await model.reload() }
    }

    /// Rows from this pane are moved (or copied with ⌥); rows from the other pane and Finder
    /// files go to the window to transfer.
    private func handle(_ drop: PaneDrop, folder: String, copy: Bool) {
        switch drop {
        case .rows(let drag) where drag.paneID == model.id:
            moveOrCopy(drag.paths.compactMap(model.item(withID:)), to: folder, copy: copy)
        default:
            actions?.receive(drop, folder)
        }
    }

    private func moveOrCopy(_ items: [FileItem], to folder: String, copy: Bool) {
        guard !items.isEmpty else { return }
        if !copy {
            Task { await model.move(items, to: folder) }
        } else if model.source.copiesInPlace {
            Task { await model.copyInPlace(items, to: folder) }
        } else {
            copyWithin?(items, folder)
        }
    }

    /// Servers ask first because there's no Trash; this Mac moves to the Trash right away.
    private func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if model.source.deletesPermanently {
            pendingDelete = items
        } else {
            Task { await model.delete(items) }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isLocal ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Menu {
                ForEach(model.source.ancestors(of: model.path), id: \.self) { folder in
                    Button {
                        Task { await model.navigate(to: folder) }
                    } label: {
                        Label(folder == model.source.rootPath ? model.source.displayName
                                  : (folder as NSString).lastPathComponent,
                              systemImage: "folder")
                    }
                }
            } label: {
                Text(model.folderName).fontWeight(.semibold)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if isDropTarget {
                Label(String(localized: "Drop into \(folderTitle(model.path))"), systemImage: "arrow.down.to.line")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.pelican)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.newFolder() } } label: { Image(systemName: "folder.badge.plus") }
                .help(String(localized: "New Folder"))
            Button { Task { await model.back() } } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help(String(localized: "Back"))
            Button { Task { await model.up() } } label: { Image(systemName: "arrow.turn.left.up") }
                .disabled(!model.canGoUp)
                .help(String(localized: "Enclosing Folder"))
            Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }
                .toggleStyle(.button)
                .help(String(localized: "Show Hidden Files"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var deleteTitle: String {
        guard let items = pendingDelete else { return "" }
        return items.count == 1
            ? String(localized: "Delete “\(items[0].name)” permanently?")
            : String(localized: "Delete \(items.count) items permanently?")
    }

    private func folderTitle(_ folder: String) -> String {
        folder == model.source.rootPath ? model.source.displayName : (folder as NSString).lastPathComponent
    }
}

/// Home / Downloads / Desktop jumps above the local list.
struct ShortcutBar: View {
    let model: PaneModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.source.shortcuts, id: \.self) { shortcut in
                let isCurrent = model.path == shortcut.path
                Button { Task { await model.navigate(to: shortcut.path) } } label: {
                    Label(shortcut.title, systemImage: shortcut.symbol)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isCurrent ? Color.primary.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }
}

/// Item providers are only read here, one at a time, so handing them off the main actor is safe.
private struct DroppedProviders: @unchecked Sendable {
    let providers: [NSItemProvider]
    init(_ providers: [NSItemProvider]) { self.providers = providers }

    func paneDrag() async -> PaneDrag? {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.pelicanItems.identifier)
        }) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .pelicanItems) { data, _ in continuation.resume(returning: data) }
        }
        return data.flatMap { try? JSONDecoder().decode(PaneDrag.self, from: $0) }
    }

    func fileURLs() async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

/// In-place name editor: Return saves, Escape cancels, clicking away saves.
private struct RenameField: View {
    @State var name: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var finished = false

    var body: some View {
        TextField("", text: $name)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }
            }
    }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        save ? commit(name) : cancel()
    }
}

/// The file list itself. Kept apart from PaneView so that nothing it depends on changes while
/// a drag is in flight; redrawing the table under a running drag session hangs AppKit.
private struct FileTable: View {
    let model: PaneModel
    @Binding var selection: Set<PaneRow.ID>
    let actions: PaneActions?
    let onDelete: ([FileItem]) -> Void
    let onDrop: (PaneDrop, String, Bool) -> Void

    var body: some View {
        Table(of: PaneRow.self, selection: $selection, sortOrder: Bindable(model).sortOrder) {
            TableColumn(String(localized: "Name"), value: \.item.name, comparator: .localizedStandard) { row in
                nameCell(row)
            }
            .width(min: 140, ideal: 220)
            TableColumn(String(localized: "Size"), value: \.item.sortSize) { row in
                Text(row.item.size.map { $0.formatted(.byteCount(style: .file)) } ?? "–")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 72, max: 110)
            TableColumn(String(localized: "Date"), value: \.item.sortDate) { row in
                Text(dateText(row.item.modified))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 96, max: 160)
        } rows: {
            ForEach(model.rows) { row in
                TableRow(row)
                    .draggable(PaneDrag(paneID: model.id, paths: dragPaths(for: row)))
                    // Dropping on a folder goes into it; on a file, next to it.
                    .dropDestination(for: PaneDropItem.self) { items in
                        guard let drop = PaneDrop(items) else { return }
                        onDrop(drop, model.dropFolder(for: row), NSEvent.modifierFlags.contains(.option))
                    }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .onDeleteCommand { onDelete(selectedItems(selection)) }
        .contextMenu(forSelectionType: PaneRow.ID.self) { ids in
            let items = selectedItems(ids)
            if let actions, !items.isEmpty {
                Button(actions.sendTitle) { actions.send(items) }
                Divider()
            }
            if items.count == 1 {
                Button(String(localized: "Rename…")) { model.renaming = items[0].path }
            }
            Button(String(localized: "New Folder")) { Task { await model.newFolder() } }
            if !items.isEmpty {
                Divider()
                Button(model.source.deletesPermanently ? String(localized: "Delete…")
                                                       : String(localized: "Move to Trash"),
                       role: .destructive) { onDelete(items) }
            }
        } primaryAction: { ids in
            guard let id = ids.first, let item = model.item(withID: id) else { return }
            Task { await model.open(item) }
        }
    }

    private func selectedItems(_ ids: Set<PaneRow.ID>) -> [FileItem] {
        model.rows.map(\.item).filter { ids.contains($0.path) }
    }

    private func dragPaths(for row: PaneRow) -> [String] {
        selection.contains(row.id) ? model.rows.map(\.id).filter(selection.contains) : [row.id]
    }

    private func nameCell(_ row: PaneRow) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            Group {
                if row.item.isDirectory {
                    Button { Task { await model.toggle(row.item) } } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(model.expanded.contains(row.item.path) ? 90 : 0))
                            .frame(width: 12, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            Image(nsImage: FileIcon.image(for: row.item, local: model.isLocal))
                .resizable()
                .frame(width: 16, height: 16)
            if model.renaming == row.id {
                RenameField(name: row.item.name) { newName in
                    Task { await model.rename(row.item, to: newName) }
                } cancel: {
                    model.renaming = nil
                }
            } else {
                Text(row.item.name).lineLimit(1)
            }
        }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "–" }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .numeric, time: .omitted)
    }
}

extension PaneDrop {
    /// Groups row-drop items the way a pane-level drop arrives.
    init?(_ items: [PaneDropItem]) {
        let drags = items.compactMap { if case .rows(let drag) = $0 { drag } else { nil } }
        let urls = items.compactMap { if case .file(let url) = $0 { url } else { nil } }
        if let first = drags.first {
            self = .rows(PaneDrag(paneID: first.paneID, paths: drags.flatMap(\.paths)))
        } else if !urls.isEmpty {
            self = .files(urls)
        } else {
            return nil
        }
    }
}
