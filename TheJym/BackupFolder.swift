//
//  BackupFolder.swift
//  TheJym
//
//  The user-picked folder automatic backups are written to, remembered
//  across launches as a security-scoped bookmark.
//
//  A user-picked folder rather than the app's own container or its iCloud
//  container, for one decisive reason: deleting the app cannot reach it.
//  The app's Documents directory goes with the app, which fails the only
//  requirement that matters here. It also needs no iCloud entitlement, so
//  nothing about this feature touches provisioning.
//
//  The BOOKMARK lives in UserDefaults, inside the app container, so a
//  delete + reinstall forgets WHERE the folder is. The files themselves
//  survive — which is the point — and the app asks you to re-pick. That's
//  why the suggested folder name matters: after a reinstall you're looking
//  for these by memory, so a name you chose once beats a path you have to
//  reconstruct.
//

import Foundation

enum BackupFolder {
    /// Suggested when picking. The picker can only SELECT a directory, not
    /// create one, so the UI asks for a folder with this name and then
    /// reports back whatever was actually chosen — never this string. A
    /// label that says what you picked is honest; one that says what was
    /// suggested is a guess dressed as a fact.
    static let suggestedName = "TheJym Backups"

    private static let bookmarkKey = "backupFolderBookmark"

    /// Test seam: a plain directory used instead of the bookmark.
    ///
    /// Security-scoped bookmarks require a real document picker, so without
    /// this the whole write/verify/quarantine/prune path could only be
    /// tested in pieces — and the pieces agreeing proves less than the
    /// sequence working. Never set outside tests; the shipping path always
    /// goes through the bookmark.
    static var testOverrideFolder: URL?

    static var isConfigured: Bool {
        testOverrideFolder != nil || UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Remembers `url` as the backup folder. Returns false if the bookmark
    /// couldn't be made, in which case nothing is stored — better to have
    /// no folder configured than one that silently never resolves.
    @discardableResult
    static func remember(_ url: URL) -> Bool {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    enum ResolveError: LocalizedError {
        case notConfigured
        case bookmarkUnreadable
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No backup folder chosen yet"
            case .bookmarkUnreadable: return "Backup folder moved or renamed — choose it again"
            case .accessDenied: return "Lost permission to the backup folder — choose it again"
            }
        }
    }

    /// Runs `body` with the folder's URL, holding security-scoped access
    /// for exactly that long.
    ///
    /// Access is scoped to the call rather than held open because a
    /// start without a matching stop leaks the resource for the process
    /// lifetime, and backups run from three different triggers.
    static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        if let testOverrideFolder { return try body(testOverrideFolder) }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw ResolveError.notConfigured
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            throw ResolveError.bookmarkUnreadable
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ResolveError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        // A stale bookmark still resolved, so this run proceeds — but the
        // refreshed bookmark is stored so the NEXT run doesn't depend on
        // the system's willingness to resolve a stale one twice.
        if isStale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return try body(url)
    }

    /// The chosen folder's display name, or nil when none is configured.
    /// Resolved from the bookmark, so it reflects a rename.
    static var displayName: String? {
        try? withFolder { $0.lastPathComponent }
    }
}
