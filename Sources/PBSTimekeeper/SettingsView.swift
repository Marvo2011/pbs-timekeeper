import AppKit
import SwiftUI
import TimekeeperCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ServerSettingsView()
                .tabItem { Label("Server", systemImage: "server.rack") }
            FolderSettings()
                .tabItem { Label("Folders", systemImage: "folder") }
            RetentionSettings()
                .tabItem { Label("Retention", systemImage: "calendar") }
        }
        .frame(width: 560, height: 460)
        .onAppear {
            NSApplication.bringToFront()
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .alert(
            "Settings", isPresented: Binding(
                get: { model.configError != nil }, set: { if !$0 { model.configError = nil } })
        ) {
            Button("OK") { model.configError = nil }
        } message: {
            Text(model.configError ?? "")
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Back up automatically", isOn: $model.config.automaticBackups)
                Picker("Every", selection: $model.config.intervalMinutes) {
                    ForEach(AppConfig.intervalChoices, id: \.self) { minutes in
                        Text(minutes < 1440 ? "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" : "day")
                            .tag(minutes)
                    }
                }
                .disabled(!model.config.automaticBackups)
                Toggle("Open at login", isOn: $model.launchAtLogin)
            }
            Section {
                TextField("Backup ID", text: $model.config.backupID)
                Text("Snapshots are stored in the group host/\(model.config.backupID).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                if model.hasFullDiskAccess {
                    Label("PBS Timekeeper has Full Disk Access.", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                } else {
                    Label("No Full Disk Access", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                    Text("Without it, macOS hides protected folders (Desktop, Documents, Downloads, Mail, Messages, ~/Library/Accounts, …) and they are skipped. Add PBS Timekeeper in System Settings, the status here updates when you come back.")
                        .font(.callout)
                }
                Button("Open Full Disk Access Settings") { FullDiskAccess.openSettings() }
            }
            Section("proxmox-backup-client") {
                PathField(
                    title: "Path", placeholder: "bundled", path: $model.config.clientPath,
                    chooseDirectories: false)
                if let url = model.clientURL {
                    Text("Using \(url.path)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("proxmox-backup-client was not found.").font(.caption).foregroundStyle(.red)
                }
                if !Paths.fuseInstalled {
                    Text("Browsing backups needs FUSE-T (https://www.fuse-t.org).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var password = Keychain.get(.serverPassword) ?? ""
    @State private var encryptionPassword = Keychain.get(.encryptionPassword) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Proxmox Backup Server") {
                TextField("Server", text: $model.config.server.host, prompt: Text("pbs.example.com"))
                TextField("Port", value: $model.config.server.port, format: .number.grouping(.never))
                TextField("Datastore", text: $model.config.server.datastore)
                TextField("Namespace", text: $model.config.server.namespace, prompt: Text("optional"))
                TextField("User or API token", text: $model.config.server.authID, prompt: Text("user@pbs or user@pbs!token"))
                SecureField("Password or token secret", text: $password)
                    .onChange(of: password) { save(password, .serverPassword) }
                TextField("Fingerprint", text: $model.config.server.fingerprint, prompt: Text("for self-signed certificates"))
                    .font(.system(.body, design: .monospaced))
            }
            Section("Encryption") {
                PathField(
                    title: "Key file", placeholder: "none", path: $model.config.keyfile,
                    chooseDirectories: false)
                SecureField("Key password", text: $encryptionPassword)
                    .onChange(of: encryptionPassword) { save(encryptionPassword, .encryptionPassword) }
                Text("Create a key with `proxmox-backup-client key create`. Keep a copy of it somewhere else: without the key, encrypted backups cannot be restored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(testing || !model.config.server.isComplete || model.clientURL == nil)
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                    if let testResult {
                        Text(testResult).font(.callout).lineLimit(3)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save(_ value: String, _ account: Keychain.Account) {
        do {
            try Keychain.set(value, for: account)
        } catch {
            model.configError = error.localizedDescription
        }
    }

    private func test() {
        guard let client = model.clientURL else { return }
        testing = true
        testResult = nil
        let invocation = model.builder.listGroups()
        Task {
            do {
                try await ClientRunner.check(executable: client, invocation: invocation)
                testResult = "✓ Connected."
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

private struct FolderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<BackupFolder.ID>()
    @State private var excludes = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders to back up").font(.headline)
            Table($model.config.folders, selection: $selection) {
                TableColumn("") { $folder in
                    Toggle("", isOn: $folder.enabled).labelsHidden()
                }
                .width(24)
                TableColumn("Folder") { $folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(folder.path).truncationMode(.middle)
                    }
                }
                TableColumn("Archive") { $folder in
                    Text(folder.archiveName).foregroundStyle(.secondary)
                }
                .width(120)
            }
            .frame(minHeight: 160)
            HStack {
                Button { addFolders() } label: { Image(systemName: "plus") }
                Button { model.removeFolders(selection) } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("Whole disks are not backed up, only the folders listed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Exclude (one pattern per line, e.g. node_modules or *.tmp)").font(.headline)
                .padding(.top, 8)
            TextEditor(text: $excludes)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .onAppear { excludes = model.config.excludes.joined(separator: "\n") }
                .onChange(of: excludes) {
                    model.config.excludes = excludes.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
        }
        .padding()
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK else { return }
        var problems: [String] = []
        for url in panel.urls {
            do {
                try model.addFolder(url)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty {
            model.configError = problems.joined(separator: "\n")
        }
    }
}

private struct RetentionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                KeepStepper(label: "Hourly backups", value: $model.config.retention.hourly)
                KeepStepper(label: "Daily backups", value: $model.config.retention.daily)
                KeepStepper(label: "Weekly backups", value: $model.config.retention.weekly)
                KeepStepper(label: "Monthly backups", value: $model.config.retention.monthly)
                KeepStepper(label: "Yearly backups", value: $model.config.retention.yearly)
            } footer: {
                Text(
                    model.config.retention.isEmpty
                        ? "All snapshots are kept. Old ones can also be pruned on the server."
                        : "After each backup, older snapshots of this Mac are removed so that only these are kept. 0 means none of that period. The space is freed by garbage collection on the server."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeepStepper: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        Stepper(value: $value, in: 0...1000) {
            HStack {
                Text(label)
                Spacer()
                Text(value == 0 ? "–" : "\(value)").monospacedDigit()
            }
        }
    }
}

struct PathField: View {
    let title: String
    let placeholder: String
    @Binding var path: String
    let chooseDirectories: Bool

    var body: some View {
        HStack {
            TextField(title, text: $path, prompt: Text(placeholder))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = !chooseDirectories
                panel.canChooseDirectories = chooseDirectories
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url {
                    path = url.path
                }
            }
            if !path.isEmpty {
                Button { path = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
