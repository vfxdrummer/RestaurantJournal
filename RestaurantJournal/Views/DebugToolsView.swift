#if DEBUG
import SwiftUI
import SwiftData

/// DEBUG-only "Test Lab": back up the real journal, reset to zero to test the scan from scratch, then
/// restore. Not compiled into release builds.
struct DebugToolsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var backupDate = JournalBackupService.backupDate()
    @State private var confirmReset = false
    @State private var confirmRestore = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    run { "Backed up \(JournalBackupService.backup(in: modelContext)) visits." }
                } label: {
                    Label("Back up journal now", systemImage: "arrow.down.doc")
                }
                Text(backupDate.map { "Last backup: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No backup yet")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Backup")
            } footer: {
                Text("Saves your whole journal (visits, ratings, notes, voice memos, people) to a file so you can restore it after testing.")
            }

            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    Label("Reset to zero", systemImage: "trash")
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Deletes everything — locally and in iCloud — and clears scan coverage so the next scan rebuilds from your photos.")
            }

            Section {
                Button { confirmRestore = true } label: {
                    Label("Restore from backup", systemImage: "arrow.up.doc")
                }
                .disabled(backupDate == nil)
            } header: {
                Text("Restore")
            } footer: {
                Text("Wipes current data and rebuilds the journal from your last backup.")
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Test Lab")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .confirmationDialog("Reset everything to zero?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to zero", role: .destructive) {
                run { DataResetService.resetAll(in: modelContext); return "Reset to zero. Run a scan to rebuild." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all journal data locally and in iCloud. Back up first if you want it back.")
        }
        .confirmationDialog("Restore from backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Wipe & restore", role: .destructive) {
                run { "Restored \(JournalBackupService.restore(in: modelContext)) visits." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces current data with the backup from \(backupDate?.formatted(date: .abbreviated, time: .shortened) ?? "—").")
        }
    }

    /// Run a data operation with the busy flag set, then refresh the backup date + status line.
    private func run(_ operation: () -> String) {
        busy = true
        message = operation()
        backupDate = JournalBackupService.backupDate()
        busy = false
    }
}
#endif
