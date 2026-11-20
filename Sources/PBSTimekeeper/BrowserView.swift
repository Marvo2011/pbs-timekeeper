import AppKit
import SwiftUI
import TimekeeperCore

/// Files of the selected snapshot on the left, the timeline of snapshots on the right.
struct BrowserView: View {
    static let windowID = "browser"

    @State private var browser: BrowserModel
    @State private var selection = Set<BrowserModel.Entry.ID>()
    @State private var pendingRestore: PendingRestore?

    struct PendingRestore {
        var items: [BrowserModel.RestoreItem]
        var destination: URL?
        var conflicts: [String]
    }

    init(model: AppModel) {
        _browser = State(initialValue: BrowserModel(app: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
            Divider()
            TimelineBar(browser: browser)
                .frame(width: 230)
        }
        .frame(minWidth: 760, minHeight: 420)
        .task { await browser.reload() }
        .onDisappear { browser.close() }
        .onChange(of: browser.app.backupGeneration) {
            Task { await browser.reload() }
        }
        .onChange(of: browser.selectedID) { selection = [] }
        .confirmationDialog(
            conflictTitle, isPresented: Binding(
                get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { pending in
            Button("Keep Both") { run(pending, .keepBoth) }
            Button("Replace") { run(pending, .replace) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Replace” moves the existing items to the Trash.")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 6) {
            Button { browser.navigate(toDepth: (browser.location?.path.count ?? 0) - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(browser.location == nil)
            .keyboardShortcut("[", modifiers: .command)

            Button("Backed up folders") { browser.navigate(toDepth: -1) }
                .buttonStyle(.link)
            if let location = browser.location {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Button(browser.displayName(ofArchive: location.archive)) { browser.navigate(toDepth: 0) }
                    .buttonStyle(.link)
                ForEach(Array(location.path.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    Button(name) { browser.navigate(toDepth: index + 1) }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            if let snapshot = browser.selected {
                Text(snapshot.date.formatted(date: .complete, time: .shortened))
                    .font(.headline)
            }
        }
        .lineLimit(1)
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let message = browser.busyMessage ?? (browser.loadingSnapshots ? "Loading backups…" : nil) {
            ProgressView(message).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.error, browser.entries.isEmpty {
            ContentUnavailableView {
                Label("No files", systemImage: "clock.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await browser.reload() } }
            }
        } else {
            Table(browser.visibleEntries, selection: $selection) {
                TableColumn("Name") { entry in
                    HStack {
                        Image(systemName: icon(for: entry))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(browser.location == nil ? browser.displayName(ofArchive: entry.name) : entry.name)
                            .foregroundStyle(entry.isHidden ? .secondary : .primary)
                        if let original = entry.originalPath {
                            Text(original).foregroundStyle(.secondary).truncationMode(.middle)
                        }
                    }
                }
                TableColumn("Modified") { entry in
                    Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Size") { entry in
                    Text(Format.bytes(entry.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: BrowserModel.Entry.ID.self) { ids in
                Button("Restore") { restore(ids, to: nil) }
                Button("Restore To…") { restoreTo(ids) }
                if browser.location != nil {
                    Button("Show in Finder") { browser.showInFinder(entries(ids)) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let entry = entries(ids).first {
                    selection = []
                    browser.open(entry)
                }
            }
        }
    }

    private var footer: some View {
        @Bindable var browser = browser
        return HStack {
            Toggle("Show hidden files", isOn: $browser.showHidden)
                .toggleStyle(.checkbox)
            if let error = browser.error, !browser.entries.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
            }
            Spacer()
            Button("Show in Finder") { browser.showInFinder(entries(selection)) }
                .disabled(browser.location == nil)
            Button("Restore To…") { restoreTo(selection) }
                .disabled(selection.isEmpty || browser.busyMessage != nil)
            Button("Restore") { restore(selection, to: nil) }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || browser.busyMessage != nil)
        }
        .padding(10)
    }

    // MARK: Actions

    private var conflictTitle: String {
        guard let pending = pendingRestore else { return "" }
        if pending.conflicts.count == 1 {
            return "“\(pending.conflicts[0])” already exists."
        }
        return "\(pending.conflicts.count) items already exist."
    }

    private func entries(_ ids: Set<BrowserModel.Entry.ID>) -> [BrowserModel.Entry] {
        browser.entries.filter { ids.contains($0.id) }
    }

    private func icon(for entry: BrowserModel.Entry) -> String {
        if browser.location == nil {
            return "archivebox.fill"
        }
        if entry.isSymlink {
            return "arrow.turn.up.right"
        }
        return entry.isDirectory ? "folder.fill" : "doc"
    }

    private func restore(_ ids: Set<BrowserModel.Entry.ID>, to destination: URL?) {
        let items = browser.restoreItems(ids)
        guard !items.isEmpty else { return }
        let conflicts = browser.conflicts(items, destination: destination)
        let pending = PendingRestore(items: items, destination: destination, conflicts: conflicts)
        if conflicts.isEmpty {
            run(pending, .keepBoth)
        } else {
            pendingRestore = pending
        }
    }

    private func restoreTo(_ ids: Set<BrowserModel.Entry.ID>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restore(ids, to: url)
    }

    private func run(_ pending: PendingRestore, _ conflict: ConflictResolution) {
        Task { await browser.restore(pending.items, to: pending.destination, conflict: conflict) }
    }
}

/// Snapshots from newest (top) to oldest, grouped by day, with buttons to step through time.
private struct TimelineBar: View {
    @Bindable var browser: BrowserModel
    @State private var confirmRemoval: Snapshot?

    private var removalTitle: String {
        guard let snapshot = confirmRemoval else { return "" }
        return "Remove the backup of \(snapshot.date.formatted(date: .long, time: .shortened))?"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { browser.step(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Newer backup")
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button { browser.step(1) } label: { Image(systemName: "chevron.down") }
                    .help("Older backup")
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Spacer()
                Button { confirmRemoval = browser.selected } label: {
                    Image(systemName: "trash")
                }
                .help(browser.selected.flatMap(browser.removalBlocker) ?? "Remove this backup from the server")
                .disabled(browser.selected.map { browser.removalBlocker($0) != nil } ?? true)
                Button { Task { await browser.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload backups")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            List(selection: $browser.selectedID) {
                if browser.app.isBackingUp {
                    Section("Now") {
                        RunningBackupRow(app: browser.app)
                    }
                }
                ForEach(days, id: \.day) { group in
                    Section(Format.day(group.day)) {
                        ForEach(group.snapshots) { snapshot in
                            HStack(spacing: 8) {
                                if snapshot.id == browser.removing {
                                    ProgressView().controlSize(.mini).frame(width: 22)
                                } else {
                                    Capsule()
                                    .fill(snapshot.id == browser.selectedID ? Color.accentColor : .secondary.opacity(0.5))
                                    .frame(width: snapshot.id == browser.selectedID ? 22 : 12, height: 3)
                                }
                                Text(snapshot.date.formatted(date: .omitted, time: .shortened))
                                    .monospacedDigit()
                                Spacer()
                                if snapshot.protected == true {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                }
                            }
                            .tag(snapshot.id)
                            .contextMenu {
                                Button("Remove Backup…") { confirmRemoval = snapshot }
                                    .disabled(browser.removalBlocker(snapshot) != nil)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let snapshot = browser.selected, browser.removalBlocker(snapshot) == nil {
                    confirmRemoval = snapshot
                }
            }
            .alert(
                removalTitle, isPresented: Binding(
                    get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }),
                presenting: confirmRemoval
            ) { snapshot in
                Button("Remove", role: .destructive) {
                    Task { await browser.remove(snapshot) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The backup is deleted on the server and its files can no longer be restored. Files that are also part of other backups stay available there. This cannot be undone.")
            }
            Divider()
            Text("\(browser.snapshots.count) backups")
                .font(.caption).foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private var days: [(day: Date, snapshots: [Snapshot])] {
        let calendar = Calendar.current
        var result: [(day: Date, snapshots: [Snapshot])] = []
        for snapshot in browser.snapshots {
            let day = calendar.startOfDay(for: snapshot.date)
            if result.last?.day == day {
                result[result.count - 1].snapshots.append(snapshot)
            } else {
                result.append((day, [snapshot]))
            }
        }
        return result
    }
}

/// The backup in progress, on top of the timeline. It has no tag, so it cannot be selected:
/// there is nothing to browse before the snapshot is finished.
private struct RunningBackupRow: View {
    let app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Backing up… \(app.elapsedText(now: context.date))")
                        .fontWeight(.medium)
                }
                if let folder = app.currentFolder {
                    Text(FileManager.default.displayName(atPath: folder))
                        .foregroundStyle(.secondary)
                }
                Group {
                    if let progress = app.progress {
                        Text("\(progress.processed) read · \(progress.uploaded) uploaded")
                    } else if !app.progressLine.isEmpty {
                        Text(app.progressLine)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
            Button { app.stopBackup() } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop Backup")
        }
        .padding(.vertical, 2)
        .help("The backup appears on the timeline when it is finished.")
    }
}

extension Format {
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
