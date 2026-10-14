import Foundation
import Observation

@MainActor @Observable
final class Favorites {
    private static let key = "favorites"
    private(set) var servers: [Server] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Server].self, from: data) {
            servers = saved
        }
    }

    func save(_ server: Server) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        Keychain.deletePassword(account: server.keychainAccount)
        Keychain.deletePassword(account: server.keyAccount)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: Self.key)
    }
}
