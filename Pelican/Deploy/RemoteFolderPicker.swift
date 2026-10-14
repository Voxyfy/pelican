import SwiftUI

/// Picks a folder on the server by browsing, instead of typing its path.
struct RemoteFolderPicker: View {
    let source: any RemoteSource
    let choose: (String) -> Void
    @State var path: String
    @State private var folders: [FileItem] = []
    @State private var selection: FileItem.ID?
    @State private var loading = false
    @State private var problem: String?
    @State private var askingName = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { Task { await open(source.parent(of: path) ?? path) } } label: {
                    Image(systemName: "arrow.turn.left.up")
                }
                .disabled(source.parent(of: path) == nil)
                .help(String(localized: "Enclosing Folder"))
                Image(systemName: "folder.fill").foregroundStyle(Color.pelican)
                Text(path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            if let problem {
                ContentUnavailableView(String(localized: "Can't Open Folder"), systemImage: "exclamationmark.triangle",
                                       description: Text(problem))
            } else if folders.isEmpty, !loading {
                ContentUnavailableView(String(localized: "No Folders Here"), systemImage: "folder",
                                       description: Text(String(localized: "Choose this folder, or make a new one inside it.")))
            } else {
                List(folders, selection: $selection) { folder in
                    Label(folder.name, systemImage: "folder")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { Task { await open(folder.path) } }
                        .onTapGesture { selection = folder.id }
                }
            }
            Divider()
            HStack {
                Button(String(localized: "New Folder")) { askingName = true }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selection == nil ? String(localized: "Choose This Folder") : String(localized: "Choose")) {
                    choose(selection ?? path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 440, height: 420)
        .task { await open(path) }
        .alert(String(localized: "New Folder"), isPresented: $askingName) {
            TextField(String(localized: "Name"), text: $newName)
            Button(String(localized: "Create")) { Task { await makeFolder() } }
            Button(String(localized: "Cancel"), role: .cancel) { newName = "" }
        }
    }

    private func open(_ folder: String) async {
        loading = true
        defer { loading = false }
        do {
            folders = try await source.list(folder).filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            path = folder
            selection = nil
            problem = nil
        } catch {
            problem = FriendlyError.transferMessage(for: error)
        }
    }

    private func makeFolder() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        let target = (path as NSString).appendingPathComponent(name)
        do {
            try await source.createFolder(at: target)
            await open(target)
        } catch {
            problem = FriendlyError.transferMessage(for: error)
        }
    }
}
