//
//  BackupSettingsSection.swift
//  TheJym
//
//  The automatic-backup section in Settings, and the one-line pointer on
//  the Restore screen.
//
//  The organising rule: show the DIRECTORY LISTING, not a stored date. A
//  stored "last backup" is a claim the app makes about itself; a listing
//  is evidence read back from the folder. Only the listing catches the
//  case this feature exists for — backups that quietly stopped landing
//  while the app still believed they were happening.
//
//  Nothing here says "nightly", names a schedule, or implies a guarantee.
//  Backups run on app lifecycle (finishing a workout, backgrounding,
//  opening the app when the last one is stale), so the honest thing to
//  display is what IS on disk, never what will happen next.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Query private var statuses: [BackupStatus]

    @State private var showingPicker = false
    @State private var listing: BackupEngine.Listing?
    @State private var folderName: String?
    @State private var runningNow = false
    @State private var pickError: String?

    private var status: BackupStatus? { statuses.first }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()

    var body: some View {
        Section {
            if folderName == nil {
                Button {
                    showingPicker = true
                } label: {
                    Label("Choose Backup Folder…", systemImage: "folder.badge.plus")
                }
            } else {
                statusRow
                filesRow
                if let corrupt = listing?.corrupt, !corrupt.isEmpty {
                    corruptRow(count: corrupt.count)
                }
                Button {
                    backUpNow()
                } label: {
                    HStack {
                        Label("Back Up Now", systemImage: "arrow.clockwise")
                        if runningNow { Spacer(); ProgressView() }
                    }
                }
                .disabled(runningNow)
                Button {
                    showingPicker = true
                } label: {
                    Label("Change Folder…", systemImage: "folder")
                }
            }
            if let pickError {
                Text(pickError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Automatic Backup")
        } footer: {
            Text(footerText)
        }
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Last backup")
                Spacer()
                // Read from the FOLDER, with the stored date only as a
                // fallback — if the newest file on disk disagrees with
                // what the app thinks, the file wins.
                if let newest = listing?.newest {
                    Text(Self.stamp.string(from: newest.date))
                        .foregroundStyle(ageColor(newest.date))
                } else {
                    Text("Never").foregroundStyle(.red)
                }
            }
            if let s = status, let success = s.lastSuccessAt {
                Text("\(s.lastSuccessRowCount) rows · \(byteText(s.lastSuccessByteCount)) · \(s.lastSuccessFileName)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Verified \(s.lastSuccessRowCount) rows on \(Self.stamp.string(from: success))")
            }
            // The attempt and the failure are shown SEPARATELY from the
            // success. "Last backup Oct 1 · last attempt today failed:
            // folder permission lost" is actionable; a lone date isn't.
            if let s = status, let reason = s.lastFailureReason, let at = s.lastFailureAt {
                Text("Last attempt \(Self.stamp.string(from: at)) failed: \(reason)")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var filesRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName ?? "")
                if let l = listing {
                    Text("\(l.dailies.count) daily · \(l.monthlies.count) monthly · \(byteText(l.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Folder unreadable — choose it again")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Image(systemName: "folder").foregroundStyle(.secondary)
        }
    }

    /// Several quarantined files is itself the signal that something is
    /// persistently wrong, so the COUNT is surfaced rather than buried.
    private func corruptRow(count: Int) -> some View {
        Label("\(count) failed backup\(count == 1 ? "" : "s") kept for inspection",
              systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
    }

    private var footerText: String {
        let base = "A full export is written after you finish a workout, when the app goes to the background, and on opening if the last one is more than 20 hours old. "
            + "Keeps \(BackupEngine.dailiesKept) daily and \(BackupEngine.monthliesKept) monthly copies, plus latest.xlsx — the newest one, under a name you don't have to work out. "
            + "Every file is checked by reading it back and parsing it, so a backup that can't be restored is reported rather than counted. "
            + "The folder is outside the app, so deleting the app leaves the backups in place — but it forgets WHERE they are, and you'll be asked to pick the folder again."
        guard folderName != nil else { return base }
        return base + "\n\nIf the folder is in iCloud Drive, a file is written to this device immediately; uploading it is up to iCloud and can lag behind."
    }

    // MARK: - Actions

    private func refresh() {
        folderName = BackupFolder.displayName
        listing = BackupEngine.listing()
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        pickError = nil
        switch result {
        case .failure(let error):
            pickError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard BackupFolder.remember(url) else {
                pickError = "Couldn't keep access to that folder. Try one in iCloud Drive or On My iPhone."
                return
            }
            refresh()
            // Write one straight away rather than waiting for a trigger —
            // the point is to SEE it work, not to trust that it will.
            backUpNow()
        }
    }

    private func backUpNow() {
        runningNow = true
        let outcome = BackupEngine.runIfConfigured(context: context, force: true)
        runningNow = false
        if case .failure(let f)? = outcome { pickError = f.errorDescription }
        refresh()
    }

    // MARK: - Formatting

    private func ageColor(_ date: Date) -> Color {
        let age = Date.now.timeIntervalSince(date)
        if age < 48 * 3600 { return .green }
        if age < 7 * 24 * 3600 { return .orange }
        return .red
    }

    private func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

/// The pointer on the Restore screen. That screen is where someone stands
/// when a restore actually matters — after a delete and reinstall, when
/// the bookmark is gone and they're looking for these files by memory — so
/// the folder name and a way to re-pick it belong here, not only in
/// Settings.
struct BackupLocationNote: View {
    @State private var folderName: String?
    @State private var newest: Date?
    @State private var showingPicker = false

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()

    var body: some View {
        Section {
            if let folderName {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Automatic backups: \(folderName)", systemImage: "folder")
                        .font(.callout)
                    if let newest {
                        Text("Newest \(Self.dayOnly.string(from: newest)) · also saved as \(BackupEngine.latestFileName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No automatic backup folder is set. If you had one before reinstalling, the files are still there — pick the folder again to see them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                showingPicker = true
            } label: {
                Label(folderName == nil ? "Find Backup Folder…" : "Change Backup Folder…",
                      systemImage: "folder.badge.questionmark")
            }
        } footer: {
            Text("Look for a folder named \"\(BackupFolder.suggestedName)\", most likely in iCloud Drive.")
        }
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                BackupFolder.remember(url)
                refresh()
            }
        }
    }

    private func refresh() {
        folderName = BackupFolder.displayName
        newest = BackupEngine.listing()?.newest?.date
    }
}
