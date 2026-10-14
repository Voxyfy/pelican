import AppKit
import SwiftUI

/// Transmit-style connection form: icon, title, labelled rows, then Add to Servers / Connect.
struct QuickConnectForm: View {
    enum Mode { case connect, edit }

    let mode: Mode
    let connection: Connection
    let onConnect: (Server, Credential) -> Void
    let onSave: (Server, Credential) -> Void

    @State private var server: Server
    /// The password, or the key's passphrase when signing in with a key.
    @State private var password: String
    @State private var remotePath: String
    @State private var usesKey: Bool
    @State private var keyText: String?
    @State private var keyNeedsPassphrase = false
    @State private var keyProblem: String?
    @Environment(\.dismiss) private var dismiss

    init(server: Server? = nil, mode: Mode = .connect, connection: Connection,
         onConnect: @escaping (Server, Credential) -> Void = { _, _ in },
         onSave: @escaping (Server, Credential) -> Void) {
        let server = server ?? Server(name: "", host: "", username: "")
        _server = State(initialValue: server)
        _password = State(initialValue: Keychain.password(account: server.keychainAccount) ?? "")
        _remotePath = State(initialValue: server.remotePath ?? "")
        _usesKey = State(initialValue: server.usesKey == true)
        let key = server.usesKey == true ? Keychain.password(account: server.keyAccount) : nil
        _keyText = State(initialValue: key)
        _keyNeedsPassphrase = State(initialValue: key.map { (try? SSHKey.inspect($0)) ?? false } ?? false)
        self.mode = mode
        self.connection = connection
        self.onConnect = onConnect
        self.onSave = onSave
    }

    private var isValid: Bool {
        guard !server.host.trimmingCharacters(in: .whitespaces).isEmpty, !server.username.isEmpty else { return false }
        if usesKey && server.kind == .sftp {
            return keyText != nil && keyProblem == nil && (!keyNeedsPassphrase || !password.isEmpty)
        }
        return !password.isEmpty
    }

    private var cleaned: Server {
        var copy = server
        copy.host = copy.host.trimmingCharacters(in: .whitespaces)
        copy.remotePath = remotePath.isEmpty ? nil : remotePath
        let key = usesKey && copy.kind == .sftp
        copy.usesKey = key ? true : nil
        copy.keyName = key ? server.keyName : nil
        return copy
    }

    private var credential: Credential {
        if usesKey, server.kind == .sftp, let keyText { return .key(keyText, passphrase: password) }
        return .password(password)
    }

    private var addressPrompt: String {
        switch server.kind {
        case .s3: "s3.amazonaws.com"
        case .r2: String(localized: "account-id.r2.cloudflarestorage.com")
        default: "server.com"
        }
    }

    /// Switching protocol also switches the port, unless the user typed a custom one.
    private var protocolChoice: Binding<TransferProtocol> {
        Binding(get: { server.kind }, set: { new in
            if server.port == server.kind.defaultPort { server.port = new.defaultPort }
            server.kind = new
            if new != .sftp { usesKey = false }
            connection.testState = nil
        })
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: server.kind.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.pelican.gradient, in: RoundedRectangle(cornerRadius: 14))
                Text(mode == .edit ? String(localized: "Edit \(server.title)")
                                   : String(localized: "Connect via \(server.kind.title)"))
                    .font(.title2.weight(.semibold))
            }

            VStack(spacing: 0) {
                row(String(localized: "Protocol")) {
                    Picker("", selection: protocolChoice) {
                        ForEach(TransferProtocol.allCases) { item in
                            Label(item.title, systemImage: item.symbol)
                                .tag(item)
                                .selectionDisabled(!item.isAvailable)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                row(String(localized: "Name")) {
                    TextField("", text: $server.name, prompt: Text(String(localized: "Optional")))
                }
                row(server.kind.usesAccessKeys ? String(localized: "Endpoint") : String(localized: "Address")) {
                    TextField("", text: $server.host, prompt: Text(addressPrompt))
                    Text(String(localized: "Port")).foregroundStyle(.secondary)
                    TextField("", value: $server.port, format: .number.grouping(.never))
                        .frame(width: 48)
                }
                if server.kind == .s3 {
                    row(String(localized: "Region")) {
                        TextField("", text: Binding(get: { server.region ?? "" },
                                                    set: { server.region = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("us-east-1"))
                    }
                }
                row(server.kind.usesAccessKeys ? String(localized: "Access Key ID") : String(localized: "User Name")) {
                    TextField("", text: $server.username, prompt: Text(server.kind.usesAccessKeys ? "AKIA…" : "me"))
                }
                if server.kind == .sftp {
                row(String(localized: "Sign In With")) {
                    Picker("", selection: $usesKey) {
                        Text(String(localized: "Password")).tag(false)
                        Text(String(localized: "SSH Key")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                }
                if usesKey && server.kind == .sftp {
                    row(String(localized: "Key")) {
                        Button { chooseKey() } label: {
                            Label(keyText == nil ? String(localized: "Choose Key…") : (server.keyName ?? "key"),
                                  systemImage: "key.horizontal.fill")
                        }
                        .buttonStyle(.borderless)
                        if keyNeedsPassphrase {
                            Text(String(localized: "Protected")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if let keyProblem {
                        Text(keyProblem)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 106)
                            .padding(.vertical, 6)
                            .textSelection(.enabled)
                    }
                    if keyNeedsPassphrase {
                        row(String(localized: "Passphrase")) {
                            SecureField("", text: $password, prompt: Text(String(localized: "key passphrase")))
                        }
                    }
                } else {
                    row(server.kind.usesAccessKeys ? String(localized: "Secret Access Key") : String(localized: "Password")) {
                        SecureField("", text: $password, prompt: Text(server.kind.usesAccessKeys
                            ? String(localized: "secret") : String(localized: "password")))
                    }
                }
                row(server.kind.usesAccessKeys ? String(localized: "Bucket") : String(localized: "Remote Path")) {
                    TextField("", text: $remotePath,
                              prompt: Text(server.kind.usesAccessKeys ? String(localized: "optional, e.g. /my-bucket")
                                                                      : "/www/project"))
                }
                .padding(.top, 14)
            }
            .textFieldStyle(.plain)

            HStack {
                Button(String(localized: "Test Connection")) {
                    Task { await connection.test(cleaned, credential: credential) }
                }
                .disabled(!isValid || connection.testState == .running)
                if connection.testState == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 12)
                if mode == .edit {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Save")) {
                        onSave(cleaned, credential)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                } else {
                    Button(String(localized: "Add to Servers")) { onSave(cleaned, credential) }
                        .disabled(!isValid)
                    Button(String(localized: "Connect")) { onConnect(cleaned, credential) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid)
                }
            }
            .controlSize(.large)

            testResult
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: 560)
        .onAppear { connection.testState = nil }
        .onChange(of: cleaned) { connection.testState = nil }
        .onChange(of: password) { connection.testState = nil }
        .onChange(of: usesKey) {
            connection.testState = nil
            password = ""
        }
    }

    /// Opens ~/.ssh, reads the chosen private key and checks it right away.
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(filePath: NSHomeDirectory()).appending(path: ".ssh")
        panel.message = String(localized: "Choose your private key, for example id_ed25519 (not the .pub file).")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !url.pathExtension.lowercased().hasPrefix("pub") else {
            keyText = nil
            keyProblem = String(localized: "That's a public key. Choose the file without .pub.")
            return
        }
        server.keyName = url.lastPathComponent
        keyText = text
        password = ""
        connection.testState = nil
        do {
            keyNeedsPassphrase = try SSHKey.inspect(text)
            keyProblem = nil
        } catch {
            keyNeedsPassphrase = false
            keyProblem = error.localizedDescription
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch connection.testState {
        case .succeeded(let folder):
            resultBanner(String(localized: "Connection works. Signed in and opened \(folder)."),
                         symbol: "checkmark.circle.fill", color: .green)
        case .failed(let message):
            resultBanner(message, symbol: "xmark.octagon.fill", color: .red)
        case .running, nil:
            EmptyView()
        }
    }

    private func resultBanner(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                content()
            }
            .frame(minHeight: 36)
            Divider()
        }
    }
}
