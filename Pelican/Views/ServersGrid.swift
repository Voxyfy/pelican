import SwiftUI

/// Saved servers as cards. Double-click connects; right-click edits or deletes.
struct ServersGrid: View {
    let connection: Connection
    let search: String
    let onEdit: (Server) -> Void
    let onNew: () -> Void
    @State private var selection: Server.ID?

    private var servers: [Server] {
        let all = connection.favorites.servers
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        if connection.favorites.servers.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Servers Yet"), systemImage: "server.rack")
            } description: {
                Text(String(localized: "Fill in Quick Connect and choose Add to Servers."))
            } actions: {
                Button(String(localized: "Quick Connect…"), action: onNew)
            }
        } else if servers.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                    ForEach(servers) { server in
                        card(server)
                    }
                }
                .padding(18)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
    }

    private func card(_ server: Server) -> some View {
        let isSelected = selection == server.id
        let isConnecting = connection.connecting?.id == server.id
        return VStack(spacing: 8) {
            ZStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.pelican.gradient, in: RoundedRectangle(cornerRadius: 12))
                if isConnecting {
                    ProgressView().controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                }
            }
            Text(server.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(server.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.pelican.opacity(0.18) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { connectOrEdit(server) }
        .onTapGesture { selection = server.id }
        .contextMenu {
            Button(String(localized: "Connect")) { connectOrEdit(server) }
            Button(String(localized: "Edit…")) { onEdit(server) }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) { connection.favorites.remove(server) }
        }
    }

    private func connectOrEdit(_ server: Server) {
        if !connection.open(server) { onEdit(server) }
    }
}
