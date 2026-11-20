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
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
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
    @State private var showModeInfo = false

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
            Section("Change detection") {
                Picker("Mode", selection: $model.config.changeDetection) {
                    ForEach(ChangeDetectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(ChangeDetectionInfo.summary(model.config.changeDetection))
                    .font(.callout).foregroundStyle(.secondary)
                if model.config.changeDetection == .legacy && model.config.intervalMinutes < 360 {
                    Text("Legacy mode reads all files on every backup. With backups every \(model.config.intervalMinutes / 60) hour(s), large folders may keep the Mac busy most of the time.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("How do these modes work?") { showModeInfo = true }
                    .buttonStyle(.link)
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
                    .onChange(of: model.config.clientPath) { model.refreshClientVersion() }
                if let url = model.clientURL {
                    Text("Using \(model.clientVersion.map { "version \($0)" } ?? "version unknown"), \(model.clientIsBundled ? "bundled with the app" : url.path)")
                        .font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: $showModeInfo) { ChangeDetectionInfo() }
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var password = Keychain.get(.serverPassword) ?? ""
    @State private var encryptionPassword = Keychain.get(.encryptionPassword) ?? ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var showCreateKey = false
    @State private var showPaperKey = false

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
                let keyInfo = EncryptionKey.info(at: model.config.keyfile)
                if model.config.keyfile.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("Backups are not encrypted.", systemImage: "lock.open")
                        .foregroundStyle(.orange)
                    Button("Create Encryption Key…") { showCreateKey = true }
                } else if let keyInfo {
                    Label("Encrypted with key \(keyInfo.shortFingerprint)", systemImage: "lock.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Button("Show Paper Key…") { showPaperKey = true }
                        Button("Create New Key…") { showCreateKey = true }
                    }
                } else {
                    Label("The key file cannot be read.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                PathField(
                    title: "Key file", placeholder: "none", path: $model.config.keyfile,
                    chooseDirectories: false)
                if keyInfo?.passwordProtected ?? false {
                    SecureField("Key password", text: $encryptionPassword)
                        .onChange(of: encryptionPassword) { save(encryptionPassword, .encryptionPassword) }
                }
                Text("Without the key, encrypted backups cannot be restored. Keep a printed paper key or a copy of the key file outside this Mac.")
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
        .sheet(isPresented: $showCreateKey) {
            CreateKeySheet().environment(model)
        }
        .sheet(isPresented: $showPaperKey) {
            PaperKeyView(keyPath: model.config.keyfile, isNewKey: false).environment(model)
        }
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
                Toggle("Remove old backups after each backup", isOn: $model.config.retention.enabled)
            } footer: {
                Text(
                    model.config.retention.enabled
                        ? "PBS Timekeeper prunes the backups of this Mac on the server after each backup. Your server user needs the DatastorePowerUser role (Datastore.Prune) for this."
                        : "Off: PBS Timekeeper never removes backups by itself. Set up a prune job for the datastore or namespace on the Proxmox Backup Server (Datastore → Prune & GC), otherwise all backups are kept and the datastore keeps growing."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                KeepStepper(label: "Hourly backups", value: $model.config.retention.hourly)
                KeepStepper(label: "Daily backups", value: $model.config.retention.daily)
                KeepStepper(label: "Weekly backups", value: $model.config.retention.weekly)
                KeepStepper(label: "Monthly backups", value: $model.config.retention.monthly)
                KeepStepper(label: "Yearly backups", value: $model.config.retention.yearly)
            } header: {
                Text("Keep")
            } footer: {
                Text(
                    model.config.retention.isEmpty
                        ? "Nothing is pruned while all values are 0."
                        : "Older snapshots are removed so that only these are kept. 0 means none of that period. The space is freed by garbage collection on the server."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.config.retention.enabled)
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

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("PBS Timekeeper").font(.title.bold())
            Text("Version \(Versions.app())")
                .textSelection(.enabled)
            Text("Scheduled folder backups to a Proxmox Backup Server.")
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("PBS Timekeeper", value: Versions.app())
                LabeledContent("proxmox-backup-client") {
                    Text(model.clientVersion ?? (model.clientURL == nil ? "not found" : "unknown"))
                        .textSelection(.enabled)
                }
                LabeledContent("Client location") {
                    Text(model.clientIsBundled ? "bundled with the app" : model.clientURL?.path ?? "–")
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let bundled = Versions.bundledClient(), !model.clientIsBundled {
                    LabeledContent("Bundled client", value: bundled.replacingOccurrences(of: "-", with: "+"))
                }
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)

            HStack(spacing: 16) {
                Link("PBS Timekeeper", destination: URL(string: "https://github.com/Marvo2011/pbs-timekeeper")!)
                Link("proxmox-backup-client for macOS", destination: URL(string: "https://github.com/Marvo2011/proxmox-backup-client-mac")!)
            }
            .font(.callout)
            Text("AGPL-3.0. Not affiliated with Proxmox Server Solutions GmbH or Apple Inc.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.refreshClientVersion() }
    }
}
