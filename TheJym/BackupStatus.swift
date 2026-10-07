//
//  BackupStatus.swift
//  TheJym
//
//  What the last backup attempt actually did. Three facts, not one:
//  when a backup last SUCCEEDED, when one was last ATTEMPTED, and why the
//  last failure failed.
//
//  "Last backup: Oct 1" on its own is the shape of answer that leaves you
//  guessing — it can't distinguish "nothing has been tried since" from
//  "it's been trying every day and failing." Keeping the attempt and the
//  reason separate makes "last backup Oct 1 · last attempt today failed:
//  folder permission lost" sayable, which is actionable where a single
//  date isn't.
//
//  Deliberately NOT carried by ExportBuilder/ImportEngine. A restored
//  install inheriting the old device's "last backup" date would be exactly
//  the false reassurance this whole feature exists to prevent: the one
//  moment you most need to know the backups are stale is the moment right
//  after a restore.
//

import Foundation
import SwiftData

@Model
final class BackupStatus {
    /// When a backup last wrote AND verified. nil until the first one.
    var lastSuccessAt: Date?
    /// Rows and bytes in that verified file — the evidence it was real,
    /// not just that `write` returned without throwing.
    var lastSuccessRowCount: Int = 0
    var lastSuccessByteCount: Int = 0
    var lastSuccessFileName: String = ""

    /// When a backup was last ATTEMPTED, successful or not. Equal to
    /// lastSuccessAt on a healthy install; ahead of it when something is
    /// wrong, which is the whole point of storing it separately.
    var lastAttemptAt: Date?

    /// Why the most recent failure failed, in words meant to be read on
    /// the Settings screen. Cleared on success.
    var lastFailureReason: String?
    var lastFailureAt: Date?

    init() {}
}
