import AppKit
import SwiftUI

/// "Publish": local folders linked to folders on this server, sent with only what changed.
struct DeploySheet: View {
    let server: Server
    let source: any RemoteSource
    let currentRemotePath: String
    let isSaved: Bool
    let queue: TransferQueue
    let targets: DeployTargets
    let onPublished: () -> Void

    private enum Screen: Equatable { case list, edit(DeployTarget), preview(DeployTarget) }
    @State private var screen = Screen.list
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch screen {
            case .list: list
            case .edit(let target):
                DeployTargetForm(target: target, source: source) { saved, token in
                    targets.save(saved)
                    if let token { Keychain.setPassword(token, account: saved.cloudflareTokenAccount) }
                    screen = .list
                } cancel: { screen = .list }
            case .preview(let target):
                DeployPreview(target: target, source: source, queue: queue, targets: targets,
                              refresh: onPublished, close: { dismiss() }, back: { screen = .list })
            }
        }
        .frame(width: 580, height: 540)
    }

    private var list: some View {
        VStack(spacing: 0) {
            header(String(localized: "Publish to \(server.title)"),
                   subtitle: String(localized: "Send only what changed from a folder on this Mac."))
            Divider()
            let saved = targets.targets(for: server)
            if !isSaved {
                ContentUnavailableView(String(localized: "Save This Server First"), systemImage: "star",
                                       description: Text(String(localized: "Publishing remembers sites per saved server. Add this server to Servers, then come back.")))
            } else if saved.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Sites Yet"), systemImage: "paperplane")
                } description: {
                    Text(String(localized: "Link a folder on this Mac to a folder on the server, for example ~/code/site → /public_html."))
                } actions: {
                    Button(String(localized: "Add Site…")) { screen = .edit(newTarget()) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(saved) { target in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.pelican)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.name).font(.headline)
                            Text("\(abbreviate(target.localPath)) → \(target.remotePath)")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(target.lastDeploy.map { String(localized: "Last published \($0.formatted(.relative(presentation: .named)))") }
                                 ?? String(localized: "Never published"))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Menu {
                            Button(String(localized: "Edit…")) { screen = .edit(target) }
                            Button(String(localized: "Delete"), role: .destructive) { targets.remove(target) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        Button(String(localized: "Preview…")) { screen = .preview(target) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                if isSaved, !saved.isEmpty {
                    Button(String(localized: "Add Site…")) { screen = .edit(newTarget()) }
                }
                Spacer()
                Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
    }

    private func newTarget() -> DeployTarget {
        // At the very top of a server the right folder is rarely "/", so make the user choose.
        DeployTarget(name: "", serverID: server.id, localPath: "",
                     remotePath: currentRemotePath == source.rootPath ? "" : currentRemotePath)
    }
}

/// Title block shared by the sheet's screens.
private func header(_ title: String, subtitle: String) -> some View {
    VStack(spacing: 4) {
        Text(title).font(.title3.weight(.semibold))
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(18)
}

/// "~/code/site" instead of the full path. In the sandbox NSHomeDirectory() is the app's
/// container, so the real home folder comes from the user database.
private func abbreviate(_ path: String) -> String {
    guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return path }
    let home = String(cString: dir)
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.hasPrefix(home + "/") ? "~" + trimmed.dropFirst(home.count) : trimmed
}

// MARK: - Site form

private struct DeployTargetForm: View {
    @State var target: DeployTarget
    let source: any RemoteSource
    let save: (DeployTarget, String?) -> Void
    let cancel: () -> Void
    @State private var excludes: String
    @State private var token: String
    @State private var cloudflare: Bool
    @State private var pickingRemote = false

    init(target: DeployTarget, source: any RemoteSource, save: @escaping (DeployTarget, String?) -> Void,
         cancel: @escaping () -> Void) {
        _target = State(initialValue: target)
        self.source = source
        _excludes = State(initialValue: target.excludes.joined(separator: "\n"))
        _token = State(initialValue: Keychain.password(account: target.cloudflareTokenAccount) ?? "")
        _cloudflare = State(initialValue: target.usesCloudflare)
        self.save = save
        self.cancel = cancel
    }

    private var isValid: Bool {
        !target.localPath.isEmpty && !target.remotePath.isEmpty && (!cloudflare || (!(target.cloudflareZone ?? "").isEmpty && !token.isEmpty))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $target.name, prompt: Text(String(localized: "My Site")))
                    LabeledContent(String(localized: "Folder on This Mac")) {
                        HStack {
                            Text(target.localPath.isEmpty ? String(localized: "None") : abbreviate(target.localPath))
                                .foregroundStyle(target.localPath.isEmpty ? .tertiary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button(String(localized: "Choose…")) { chooseFolder() }
                        }
                    }
                    LabeledContent(String(localized: "Folder on Server")) {
                        HStack {
                            TextField("", text: $target.remotePath, prompt: Text("/public_html"))
                                .labelsHidden()
                            Button(String(localized: "Choose…")) { pickingRemote = true }
                        }
                    }
                }
                Section {
                    TextEditor(text: $excludes)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 96)
                } header: {
                    Text(String(localized: "Never Send"))
                } footer: {
                    Text(String(localized: "One per line. A name like node_modules or *.log matches anywhere; a path like storage/logs matches that folder."))
                }
                Section {
                    Toggle(String(localized: "Delete server files that are gone from this Mac"), isOn: $target.deleteRemoved)
                    if target.deleteRemoved {
                        Label(String(localized: "Files uploaded to the server some other way, like user uploads, will be deleted too."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle(String(localized: "Clear Cloudflare's cache after publishing"), isOn: $cloudflare)
                    if cloudflare {
                        TextField(String(localized: "Zone ID"), text: Binding(get: { target.cloudflareZone ?? "" },
                                                                            set: { target.cloudflareZone = $0 }))
                        SecureField(String(localized: "API Token"), text: $token)
                        TextField(String(localized: "Site Address"), text: Binding(get: { target.siteURL ?? "" },
                                                                                 set: { target.siteURL = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("https://example.com"))
                    }
                } footer: {
                    if cloudflare {
                        Text(String(localized: "The token needs the Zone › Cache Purge permission. With a site address only changed pages are cleared; without one, the whole cache is."))
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $pickingRemote) {
                RemoteFolderPicker(source: source, choose: { target.remotePath = $0 },
                                   path: target.remotePath.isEmpty ? source.startPath : target.remotePath)
            }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    var saved = target
                    saved.excludes = excludes.split(whereSeparator: \.isNewline).map(String.init)
                    if saved.name.isEmpty { saved.name = (saved.localPath as NSString).lastPathComponent }
                    if !cloudflare { saved.cloudflareZone = nil; saved.siteURL = nil }
                    save(saved, cloudflare ? token : "")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(14)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder whose contents go to the server.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target.localPath = url.path(percentEncoded: false)
        target.localBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
        if target.name.isEmpty { target.name = url.lastPathComponent }
    }
}

// MARK: - Preview

private struct DeployPreview: View {
    let target: DeployTarget
    let source: any RemoteSource
    let queue: TransferQueue
    let targets: DeployTargets
    /// Re-reads the server pane once the deploy has finished.
    let refresh: () -> Void
    let close: () -> Void
    let back: () -> Void

    @State private var plan: DeployPlan?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            header(target.name, subtitle: "\(abbreviate(target.localPath)) → \(target.remotePath)")
            Divider()
            Group {
                if let problem {
                    ContentUnavailableView(String(localized: "Can't Compare"), systemImage: "exclamationmark.triangle",
                                           description: Text(problem))
                } else if let plan {
                    summary(plan)
                } else {
                    ProgressView(String(localized: "Comparing with the server…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button(String(localized: "Back"), action: back)
                Spacer()
                Button(publishTitle) { publish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan?.isEmpty != false)
            }
            .padding(14)
        }
        .task { await compare() }
    }

    private var publishTitle: String {
        guard let plan, !plan.isEmpty else { return String(localized: "Publish") }
        return String(localized: "Publish \(plan.uploads.count + plan.deletions.count) Changes")
    }

    private func summary(_ plan: DeployPlan) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                tile(String(localized: "To Upload"), "\(plan.uploads.count)",
                     plan.uploadBytes.formatted(.byteCount(style: .file)), .pelican)
                tile(String(localized: "To Delete"), "\(plan.deletions.count)",
                     target.deleteRemoved ? String(localized: "on the server") : String(localized: "off"), .red)
                tile(String(localized: "Unchanged"), "\(plan.unchanged)", String(localized: "skipped"), .secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            if plan.isEmpty {
                ContentUnavailableView(String(localized: "Everything's Up to Date"), systemImage: "checkmark.circle",
                                       description: Text(String(localized: "Nothing changed since the last publish.")))
            } else {
                List {
                    if !plan.uploads.isEmpty {
                        Section(String(localized: "Upload")) {
                            ForEach(plan.uploads.prefix(300), id: \.relative) { file in
                                HStack {
                                    Image(systemName: "arrow.up.circle").foregroundStyle(Color.pelican)
                                    Text(file.relative).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(file.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                    if !plan.deletions.isEmpty {
                        Section(String(localized: "Delete")) {
                            ForEach(plan.deletions.prefix(300), id: \.self) { path in
                                Label(path, systemImage: "minus.circle").foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.weight(.semibold)).foregroundStyle(color).monospacedDigit()
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func compare() async {
        guard let folder = target.openLocalFolder() else {
            problem = String(localized: "Pelican can't open \(abbreviate(target.localPath)). Edit the site and choose the folder again.")
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            plan = try await DeployPlanner.plan(local: folder, remote: source, remoteRoot: target.remotePath,
                                                excludes: target.excludes, deleteRemoved: target.deleteRemoved,
                                                manifest: DeployManifest.load(for: target))
        } catch {
            problem = FriendlyError.transferMessage(for: error)
        }
    }

    private func publish() {
        guard let plan, let folder = target.openLocalFolder() else { return }
        let target = self.target
        let targets = self.targets
        let log = ActivityLog.shared
        let refresh = self.refresh
        var transfer: Transfer?
        transfer = queue.deploy(plan, name: target.name, to: target.remotePath, via: source) {
            folder.stopAccessingSecurityScopedResource()
            refresh()
            guard transfer?.state == .done else { return }
            plan.manifest.save(for: target)
            var updated = target
            updated.lastDeploy = .now
            targets.save(updated)
            log.success(String(localized: "Published \(target.name): \(plan.uploads.count) uploaded, \(plan.deletions.count) deleted."))
            if updated.usesCloudflare, let zone = updated.cloudflareZone,
               let token = Keychain.password(account: updated.cloudflareTokenAccount) {
                let urls = updated.siteURL.map { Cloudflare.urls(for: plan.uploads.map(\.relative) + plan.deletions, site: $0) }
                Task {
                    do {
                        try await Cloudflare.purge(zone: zone, token: token, urls: urls)
                        log.success(String(localized: "Cleared Cloudflare's cache for \(target.name)."))
                    } catch {
                        log.error(String(localized: "Couldn't clear Cloudflare's cache: \(error.localizedDescription)"))
                    }
                }
            }
        }
        close()
    }
}
