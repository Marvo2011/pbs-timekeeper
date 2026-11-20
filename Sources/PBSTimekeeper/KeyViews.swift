import AppKit
import SwiftUI
import TimekeeperCore
import WebKit

/// Creates the encryption key and then shows its paper key.
struct CreateKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var error: String?
    /// Set once the key exists, switches the sheet to the paper key.
    @State private var createdKey: String?

    var body: some View {
        if let createdKey {
            PaperKeyView(keyPath: createdKey, isNewKey: true)
        } else {
            form
        }
    }

    private var hasKey: Bool {
        !model.config.keyfile.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(hasKey ? "Create a New Encryption Key" : "Create an Encryption Key", systemImage: "key.fill")
                .font(.title2.bold())
            Text("Your backups will be encrypted on this Mac before they are uploaded. The server only stores encrypted data and cannot read your files.")
            if hasKey {
                WarningBox(
                    title: "Your current key stays important",
                    text: "Backups made so far can only be restored with the current key. It is kept next to the new one, but make sure you also have a copy of it elsewhere. Browsing those older backups in PBS Timekeeper is no longer possible after switching, and the next backup uploads everything again.")
            }
            WarningBox(
                title: "Keep a copy of the key in a safe place",
                text: "Without the key, encrypted backups cannot be restored — not by you, the server administrator or Proxmox. If this Mac is lost, the key is lost with it. After creating the key, print the paper key and save a copy of the key file outside this Mac.")
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(hasKey ? "Create New Key" : "Create Key") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || model.clientURL == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func create() {
        guard let client = model.clientURL else { return }
        creating = true
        error = nil
        let builder = model.builder
        Task {
            do {
                let url = EncryptionKey.defaultLocation
                try EncryptionKey.moveAside(url)
                try await EncryptionKey.create(at: url, executable: client, builder: builder)
                model.config.keyfile = url.path
                // the new key has no password
                try? Keychain.set("", for: .encryptionPassword)
                createdKey = url.path
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}

/// The paper key with the key as text and QR code, to print and keep.
struct PaperKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let keyPath: String
    /// A new key has to be confirmed as saved before the sheet closes.
    let isNewKey: Bool

    @State private var html: String?
    @State private var error: String?
    @State private var confirmed = false
    @State private var webView = WKWebView()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isNewKey ? "Your Encryption Key Was Created" : "Paper Key", systemImage: "key.fill")
                .font(.title2.bold())
            WarningBox(
                title: "Store a copy of this key outside this Mac",
                text: "Print this page and keep it somewhere safe, and save the key file to a password manager or a USB stick. Without the key your backups cannot be restored. Anyone who has it can read your backups, so keep it like a password. To restore on another computer, scan the QR code or type the key into a file and use it with proxmox-backup-client.")
            if let info = EncryptionKey.info(at: keyPath) {
                Text("Fingerprint: \(info.fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if info.passwordProtected {
                    Text("This key is protected by a password. You need the password as well to use the paper key, keep it safe too.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Group {
                if let html {
                    PaperKeyWebView(webView: webView, html: html)
                        .border(Color.secondary.opacity(0.3))
                } else if let error {
                    Text(error).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 320)

            HStack {
                Button("Print…") { print() }
                    .disabled(html == nil)
                Button("Save Key File…") { saveKeyFile() }
                Spacer()
                if isNewKey {
                    Toggle("I have stored a copy of the key in a safe place", isOn: $confirmed)
                        .toggleStyle(.checkbox)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNewKey && !confirmed)
            }
        }
        .padding(20)
        .frame(width: 720, height: 680)
        .interactiveDismissDisabled(isNewKey && !confirmed)
        .task { await load() }
    }

    private var subject: String {
        let server = model.config.server
        return "PBS Timekeeper encryption key – host/\(model.config.backupID) on \(server.host)/\(server.datastore)"
    }

    private func load() async {
        guard let client = model.clientURL else {
            error = "proxmox-backup-client was not found."
            return
        }
        do {
            html = try await EncryptionKey.paperKey(
                at: keyPath, subject: subject, executable: client, builder: model.builder)
        } catch {
            self.error = "The paper key could not be created: \(error.localizedDescription)"
        }
    }

    private func print() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.jobTitle = "PBS Timekeeper Paper Key"
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func saveKeyFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pbs-timekeeper-\(model.config.backupID)-key.json"
        panel.message = "Save a copy of the key outside this Mac, e.g. on a USB stick or in a password manager."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PaperKeyWebView: NSViewRepresentable {
    let webView: WKWebView
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WarningBox: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
