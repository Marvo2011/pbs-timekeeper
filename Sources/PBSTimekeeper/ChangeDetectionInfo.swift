import SwiftUI
import TimekeeperCore

/// Explains the change detection modes of proxmox-backup-client.
struct ChangeDetectionInfo: View {
    @Environment(\.dismiss) private var dismiss

    static func summary(_ mode: ChangeDetectionMode) -> String {
        switch mode {
        case .metadata:
            "Only new and changed files are read. Unchanged files are taken over from the previous backup by comparing their metadata. Fast, the right choice for frequent backups."
        case .legacy:
            "Every backup reads all files completely. Only data the server does not have yet is uploaded, but reading takes as long as the first backup."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How changes are detected").font(.title2.bold())
                    Text("Every backup is a complete snapshot on the server: each one can be browsed and restored on its own, none depends on you keeping an older one. The modes differ in how much work the Mac does to create it.")

                    section(
                        "Metadata (recommended)", icon: "bolt.fill",
                        """
                        Each folder is stored as two archives: a small metadata archive (.mpxar) with the names, sizes, dates and permissions of all files, and a payload archive (.ppxar) with the file contents.

                        On the next backup, the client goes through the folder and compares the metadata of every file with the previous snapshot. A file whose size and dates are unchanged is not read again: the new snapshot points to its contents in the previous one. Only new and changed files are read, encrypted and uploaded.
                        """)

                    section(
                        "Legacy", icon: "tortoise.fill",
                        """
                        Each folder is one archive (.pxar) with metadata and contents together.

                        Every backup reads every file completely and splits it into chunks. The server already has most of these chunks, so only new ones are uploaded (deduplication), and the storage used on the server is the same. But all the reading happens every time: a backup of a large home folder takes about as long as the first one, for example 20 minutes for 180 GB instead of one or two.
                        """)

                    section(
                        "Why metadata is better here", icon: "checkmark.seal.fill",
                        """
                        • Much faster: backups take minutes or seconds instead of reading everything again, so hourly backups are practical.
                        • Less load: far less disk activity, CPU and battery use, the Mac stays responsive.
                        • Shorter windows: a backup that finishes quickly is less likely to be interrupted by sleep or a lost network.
                        """)

                    section(
                        "When legacy can make sense", icon: "questionmark.circle",
                        """
                        • Programs that change file contents but restore the old modification date. The metadata mode would not notice such a change until the file's metadata changes. This is very rare.
                        • Tools that only understand single .pxar archives, such as older Proxmox Backup Server versions or scripts that expect them.
                        • Rare backups, e.g. once a day, where the extra reading does not matter.

                        The metadata mode keeps the archives tidy by itself: when reusing the old data of unchanged files would carry along more than 10 % unused data (parts of chunks shared with files that changed), it reads those files again instead.
                        """)

                    section(
                        "Switching", icon: "arrow.left.arrow.right",
                        """
                        You can switch at any time. Snapshots of both kinds can be browsed and restored. The first backup after a switch reads all files once, because the previous snapshot has the other format, and later backups follow the new mode.
                        """)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
    }

    private func section(_ title: String, icon: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
