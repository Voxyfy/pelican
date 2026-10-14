import SwiftUI

/// Right pane: Servers / Quick Connect tabs until connected, then the server's files.
struct RemoteSide: View {
    let connection: Connection
    let actions: PaneActions?
    let copyWithin: ([FileItem], String) -> Void
    let search: String
    @Binding var tab: Tab
    @State private var editing: Server?

    enum Tab { case servers, quickConnect }

    var body: some View {
        Group {
            if let pane = connection.pane, let server = connection.server {
                PaneView(model: pane, actions: actions, copyWithin: copyWithin) { serverBar(server) }
            } else {
                VStack(spacing: 0) {
                    tabBar.frame(height: 30)
                    Divider()
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: connection.needsPassword) { _, server in
            if let server {
                editing = server
                connection.needsPassword = nil
            }
        }
        .sheet(item: $editing) { server in
            QuickConnectForm(server: server, mode: .edit, connection: connection) { saved, credential in
                connection.save(saved, credential: credential)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let server = connection.connecting {
            ProgressView(String(localized: "Connecting to \(server.title)…"))
        } else {
            VStack(spacing: 0) {
                if let error = connection.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.85))
                }
                switch tab {
                case .servers:
                    ServersGrid(connection: connection, search: search,
                                onEdit: { editing = $0 }, onNew: { tab = .quickConnect })
                case .quickConnect:
                    ScrollView {
                        QuickConnectForm(
                            connection: connection,
                            onConnect: { server, credential in
                                Task { await connection.connect(server, credential: credential) }
                            },
                            onSave: { server, credential in
                                connection.save(server, credential: credential)
                                tab = .servers
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            tabButton(String(localized: "Servers"), symbol: "server.rack", tab: .servers)
            tabButton(String(localized: "Quick Connect"), symbol: "bolt.fill", tab: .quickConnect)
        }
    }

    private func tabButton(_ title: String, symbol: String, tab target: Tab) -> some View {
        let isSelected = tab == target
        return Button { tab = target } label: {
            Label(title, systemImage: symbol)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? Color.pelican : .secondary)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if isSelected { Rectangle().fill(Color.pelican).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func serverBar(_ server: Server) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
            Text(server.title).fontWeight(.semibold)
            Text(server.host).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await connection.disconnect() } } label: {
                Label(String(localized: "Disconnect"), systemImage: "eject.fill")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Disconnect"))
        }
        .font(.callout)
        .padding(.horizontal, 12)
    }
}
