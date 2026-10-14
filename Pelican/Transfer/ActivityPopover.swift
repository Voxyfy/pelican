import SwiftUI

/// Transmit-style "Server Activity": transfers on top, then a timestamped log.
struct ActivityPopover: View {
    let queue: TransferQueue
    let log: ActivityLog
    @State private var errorsOnly = false

    private var shown: [ActivityLog.Entry] {
        errorsOnly ? log.entries.filter { $0.level == .error } : log.entries
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !queue.transfers.isEmpty {
                            sectionTitle(String(localized: "Transfers")) {
                                if queue.hasFinished {
                                    Button(String(localized: "Clear Finished")) { queue.clearFinished() }
                                        .buttonStyle(.borderless)
                                }
                            }
                            ForEach(queue.transfers) { transfer in
                                TransferRow(transfer: transfer) { queue.cancel(transfer) }
                                Divider().padding(.leading, 44)
                            }
                        }
                        sectionTitle(String(localized: "Log")) { EmptyView() }
                        if shown.isEmpty {
                            Text(errorsOnly ? String(localized: "No errors.") : String(localized: "Nothing yet."))
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                        ForEach(shown) { entry in
                            LogLine(entry: entry).id(entry.id)
                        }
                    }
                }
                .onAppear { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: log.entries.count) {
                    if let last = shown.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .frame(width: 480, height: 440)
    }

    private var header: some View {
        HStack {
            Button { log.copy(shown) } label: { Image(systemName: "doc.on.doc") }
                .help(String(localized: "Copy Log"))
                .disabled(shown.isEmpty)
            Spacer()
            Text(String(localized: "Server Activity")).font(.headline)
            Spacer()
            Picker("", selection: $errorsOnly) {
                Text(String(localized: "All")).tag(false)
                Text(String(localized: "Errors Only")).tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Button(String(localized: "Clear")) { log.clear() }
                .disabled(log.entries.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func sectionTitle<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            accessory().font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct LogLine: View {
    let entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(.dateTime.hour().minute().second()))
                .foregroundStyle(.tertiary)
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            Text(entry.message)
                .foregroundStyle(entry.level == .error ? Color.red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch entry.level {
        case .info: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .success: .green
        case .error: .red
        }
    }
}

/// The toolbar's ↑↓ button: fills a ring while transfers run and opens Server Activity.
struct ActivityButton: View {
    let queue: TransferQueue
    let log: ActivityLog
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            ZStack {
                if queue.activeCount > 0 {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(queue.activeFraction, 0.03))
                        .stroke(Color.pelican, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: queue.activeFraction)
                }
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(log.errorCount > 0 && queue.activeCount == 0 ? Color.red : .primary)
            }
            .frame(width: 24, height: 24)
        }
        .badge(queue.activeCount)
        .help(String(localized: "Server Activity"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            ActivityPopover(queue: queue, log: log)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.pelican)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                switch transfer.state {
                case .preparing:
                    ProgressView().progressViewStyle(.linear)
                case .running:
                    ProgressView(value: transfer.fraction).tint(Color.pelican)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                default:
                    Text(transfer.destination).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            trailing.frame(width: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch transfer.direction {
        case .upload: "arrow.up.circle.fill"
        case .download: "arrow.down.circle.fill"
        case .copy: "plus.square.on.square.fill"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch transfer.state {
        case .waiting, .preparing, .running:
            Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Cancel Transfer"))
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let bytes = { (value: Int64) in value.formatted(.byteCount(style: .file)) }
        switch transfer.state {
        case .waiting: return String(localized: "Waiting")
        case .preparing: return String(localized: "Preparing…")
        case .running: return "\(bytes(transfer.doneBytes)) / \(bytes(transfer.totalBytes))"
        case .done: return bytes(transfer.totalBytes)
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}
