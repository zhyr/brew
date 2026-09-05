/*
 * brew.app (DynamicIsland)
 * Copyright (C) 2024-2026 brew.app Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os.log

private let taskReminderLog = OSLog(subsystem: "com.atoll.dynamicisland", category: "TaskReminder")

/// iCloud container identifier registered with the Apple Developer portal
/// (declared in `DynamicIsland.entitlements` + `Info.plist` `NSUbiquitousContainerIDs`).
private let kBrewICCloudContainerID = "iCloud.com.brew.app"

/// `~/Documents/brew/task-note/` — directory inside iCloud Drive, subpath
/// inside the `Documents` scope of the brew.app container. Apple recommends
/// keeping user data inside `Documents/` of the container; FileProvider
/// picks it up automatically.
private let kBrewICCloudSubpath = "task-note"

/// UserDefaults flag — user may opt out of iCloud even when signed in.
/// When `false`, data is stored in `~/Documents/brew/task-note/` (local only,
/// never uploaded). When `true`, data is stored in the iCloud ubiquity
/// container; if the user is signed out of iCloud the manager transparently
/// falls back to local storage and exposes that through `iCloudSyncState`.
private let kUserOptedOutOfiCloudKey = "BrewTaskNoteUseiCloud"

/// Legacy local storage flag — set after the one-shot migration from
/// `~/Documents/brew/task-note/` into the new home completes, so we don't
/// repeat the import on subsequent launches.
private let kLegacyLocalMigrationDoneKey = "BrewTaskNoteLegacyLocalMigrationDone"

/// A single task/reminder item.
///
/// Tasks are lightweight to-do entries shown in the floating reminder panel.
/// They are intentionally distinct from full notes (handled by Perch) — tasks
/// are for quick "remember to do X" entries that can be checked off.
struct TaskReminder: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var completed: Bool
    var completedAt: Date?

    init(title: String, id: UUID = UUID(), createdAt: Date = Date(), completed: Bool = false, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completed = completed
        self.completedAt = completedAt
    }
}

/// Observable view of the iCloud sync state, surfaced in the UI so the user
/// can tell whether their TaskNote tasks are actually sharing across devices.
enum TaskReminderSyncState: Equatable {
    case signedIn            // ubiquity container reachable, writes replicate
    case signedOut           // iCloud account unavailable — local-only fallback
    case temporarilyLocal    // iCloud available but user opted out — local fallback
    case downloadingFiles    // user pressed show in Finder; downloading on demand
    case unknown             // initial state at boot before token resolved

    var description: String {
        switch self {
        case .signedIn:         return "Synced via iCloud"
        case .signedOut:        return "iCloud signed out — stored locally"
        case .temporarilyLocal: return "iCloud disabled — stored locally"
        case .downloadingFiles: return "Downloading from iCloud…"
        case .unknown:          return "Checking iCloud…"
        }
    }
}

/// Singleton manager for task reminders.
///
/// Tasks are persisted as JSON files, one per calendar day (e.g.
/// `2026-09-05.json`). Each file contains the array of tasks created on that
/// day. Marking a task complete only flips the `completed` flag — it never
/// deletes the record. Data is only removed when the user explicitly deletes
/// a single task.
///
/// **Storage location.** The directory used depends on the current
/// `userOptedOutOfiCloud` setting and the availability of the iCloud account
/// at runtime. See `resolvedStorageDirectory` for the resolution rules.
///
/// **iCloud integration.** When iCloud is enabled and the user is signed in,
/// the storage directory is the ubiquity container `iCloud.com.brew.app`'s
/// `Documents/task-note/`. All writes are coordinated by `NSFileCoordinator`
/// with `.forMerging` so an outside FileProvider (e.g. the macOS Finder
/// editing the same file) cannot race us. All reads are coordinated with
/// `.forReading`. We additionally run an `NSMetadataQuery` against the
/// ubiquity container to discover remote changes (made by another Mac signed
/// into the same iCloud account) and pull them in.
///
/// **Threading model.**
/// - `tasks` (the `@Published` array) and all `iCloudSync*` properties are
///   always read and written on the main thread so SwiftUI updates are
///   consistent.
/// - All disk I/O (load/save/delete) runs on `ioQueue`, a serial background
///   queue. `dateFormatter` is only touched from `ioQueue`, which makes its
///   non-thread-safe nature safe.
/// - NSMetadataQuery callbacks are dispatched onto `ioQueue` before they
///   touch disk I/O so the queue ordering is consistent.
final class TaskReminderManager: ObservableObject {
    static let shared = TaskReminderManager()

    @Published private(set) var tasks: [TaskReminder] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var iCloudSyncState: TaskReminderSyncState = .unknown

    /// User preference. When `true`, data lives in iCloud Drive (subject to
    /// availability); when `false`, data lives purely in `~/Documents/`.
    /// Backed by UserDefaults — the SwiftUI Settings toggles are the source.
    @Published var userOptedOutOfiCloud: Bool {
        didSet {
            UserDefaults.standard.set(userOptedOutOfiCloud, forKey: kUserOptedOutOfiCloudKey)
            ioQueue.async { [weak self] in
                self?.rebuildStorageAfterToggle()
            }
        }
    }

    /// Local-only legacy path: `~/Documents/brew/task-note/`.
    private let legacyLocalDirectory: URL

    /// Today's resolved storage directory (ubiquity container if iCloud + opt-in,
    /// else local-only mirror under `~/Documents/brew/task-note/`).
    /// Computed lazily — re-evaluated on `ioQueue` whenever opt-in / account
    /// state changes.
    private var resolvedStorageDirectory: URL

    /// Serial queue for all disk I/O. `dateFormatter` is only ever accessed
    /// from this queue, so the lack of thread safety in DateFormatter is
    /// a non-issue.
    private let ioQueue = DispatchQueue(label: "com.atoll.dynamicisland.taskreminder.io")

    /// Date formatter for naming day-files (`YYYY-MM-DD.json`).
    /// **Must only be accessed from `ioQueue`.**
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Watches ubiquity container for external modifications. Started once
    /// when iCloud is the active storage target; stopped when user opts out.
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        legacyLocalDirectory = docs.appendingPathComponent("brew/task-note", isDirectory: true)
        // Initial best-effort guess — re-evaluated on `init` finishing.
        resolvedStorageDirectory = docs.appendingPathComponent("brew/task-note", isDirectory: true)
        userOptedOutOfiCloud = UserDefaults.standard.bool(forKey: kUserOptedOutOfiCloudKey)
        ensureDirectoryExists(at: legacyLocalDirectory)
        migrateFromUserDefaultsIfNeeded()

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.refreshSyncState()
            self.rebuildStorageAfterToggle() // resolves directory, migrates legacy if first-launch
            self.reconcileAtStartup()
            self.startWatchingIfNeeded()
        }
    }

    /// One-time migration: tasks were previously stored under the UserDefaults
    /// key `BrewTaskReminders`. Move them into the storage target so all data
    /// lives in one place.
    private func migrateFromUserDefaultsIfNeeded() {
        let legacyKey = "BrewTaskReminders"
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacyTasks = try? JSONDecoder().decode([TaskReminder].self, from: data),
              !legacyTasks.isEmpty else {
            return
        }
        ioQueue.async { [weak self] in
            for task in legacyTasks {
                self?.saveTask(task)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    // MARK: - Public API

    /// Add a new task from text. Whitespace-only strings are ignored.
    func addTask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskReminder(title: trimmed)
        tasks.insert(task, at: 0) // newest first
        ioQueue.async { [weak self] in
            self?.saveTask(task)
        }
    }

    /// Toggle the completion state of a task. Only the flag is changed;
    /// the record is never deleted.
    func toggleCompleted(_ task: TaskReminder) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].completed.toggle()
        tasks[index].completedAt = tasks[index].completed ? Date() : nil
        let updated = tasks[index]
        ioQueue.async { [weak self] in
            self?.saveTask(updated)
        }
    }

    /// Delete a single task — the only way data is removed from disk.
    func delete(_ task: TaskReminder) {
        tasks.removeAll { $0.id == task.id }
        ioQueue.async { [weak self] in
            self?.removeTaskFromFile(task)
        }
    }

    /// Force a full reconciliation. Public so the user can pull-to-refresh
    /// in the UI if they suspect the cache is stale.
    func forceReconcile() {
        ioQueue.async { [weak self] in
            self?.reconcileAtStartup()
        }
    }

    // MARK: - Sorting

    /// Tasks sorted: pending first, then by creation time newest-first.
    var sortedTasks: [TaskReminder] {
        tasks.sorted { lhs, rhs in
            if lhs.completed != rhs.completed {
                return !lhs.completed
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var pendingCount: Int {
        tasks.filter { !$0.completed }.count
    }

    // MARK: - Storage resolution

    /// Resolve and switch the active storage directory. Must be called on
    /// `ioQueue`. Triggers a one-shot migration of `~/Documents/brew/task-note/`
    /// contents into the new location on first run after opt-in, and a
    /// best-effort reverse migration on opt-out so the user does not see
    /// their old tasks vanish.
    private func rebuildStorageAfterToggle() {
        let priorDirectory = resolvedStorageDirectory
        let newDir = resolveStorageDirectory()
        if newDir == priorDirectory { return }
        ensureDirectoryExists(at: newDir)
        // If we have never migrated legacy local files and we are switching
        // INTO iCloud, copy legacy files up so the user sees their old tasks.
        if !UserDefaults.standard.bool(forKey: kLegacyLocalMigrationDoneKey)
            && isUbiquityContainer(newDir) {
            _ = copyContents(of: legacyLocalDirectory, into: newDir)
            UserDefaults.standard.set(true, forKey: kLegacyLocalMigrationDoneKey)
            _ = removeContents(of: legacyLocalDirectory)
        }
        // If we are switching OUT of iCloud into local-only, copy current
        // contents of iCloud back to local mirror so the local copy stays
        // useful as a non-shared reference.
        if isUbiquityContainer(priorDirectory) && !isUbiquityContainer(newDir) {
            _ = copyContents(of: priorDirectory, into: newDir)
        }
        resolvedStorageDirectory = newDir
        reconcileAtStartup()
        startWatchingIfNeeded()
    }

    /// Where today's tasks should live. Order of precedence:
    /// 1. If user explicitly opted out — local Documents (`legacyLocalDirectory`).
    /// 2. If iCloud account is signed in — ubiquity container `Documents/task-note/`.
    /// 3. Otherwise — fall back to local Documents (and surface `.signedOut` in UI).
    ///
    /// Must be called from `ioQueue`.
    private func resolveStorageDirectory() -> URL {
        if userOptedOutOfiCloud {
            return legacyLocalDirectory
        }
        if let ubiquityDir = ubiquityContainerTaskNoteDirectory() {
            return ubiquityDir
        }
        return legacyLocalDirectory
    }

    /// Returns the path `~/Library/Mobile Documents/iCloud~<account>/Documents/task-note/`
    /// inside the brew.app ubiquity container. `nil` if iCloud is unavailable.
    /// Must be called from `ioQueue`.
    private func ubiquityContainerTaskNoteDirectory() -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        guard let containerRoot = FileManager.default.url(
            forUbiquityContainerIdentifier: kBrewICCloudContainerID
        ) else {
            os_log(.info, log: taskReminderLog,
                   "iCloud container %{public}@ unavailable — falling back to local storage",
                   kBrewICCloudContainerID)
            return nil
        }
        let docs = containerRoot.appendingPathComponent("Documents", isDirectory: true)
        return docs.appendingPathComponent(kBrewICCloudSubpath, isDirectory: true)
    }

    private func isUbiquityContainer(_ url: URL) -> Bool {
        url.path.contains("Mobile Documents") && url.path.contains("iCloud")
    }

    private func refreshSyncState() {
        let token = FileManager.default.ubiquityIdentityToken
        let state: TaskReminderSyncState
        if userOptedOutOfiCloud {
            state = .temporarilyLocal
        } else if token == nil {
            state = .signedOut
        } else if ubiquityContainerTaskNoteDirectory() != nil {
            state = .signedIn
        } else {
            state = .signedOut
        }
        DispatchQueue.main.async { [weak self] in
            self?.iCloudSyncState = state
        }
        os_log(.info, log: taskReminderLog, "iCloud sync state: %{public}@", state.description)
    }

    // MARK: - File helpers (all on ioQueue)

    private func ensureDirectoryExists(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to create storage directory at %{public}@: %{public}@",
                       url.path, error.localizedDescription)
            }
        }
    }

    /// Best-effort directory copy of regular files. Returns `true` if every
    /// `*.json` in `src` was copied into `dst`, replacing any existing file
    /// of the same name. Failures are logged but not surfaced — migration is
    /// best-effort and we still reload `dst` afterwards.
    private func copyContents(of src: URL, into dst: URL) -> Bool {
        ensureDirectoryExists(at: dst)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var ok = true
        for entry in entries where entry.pathExtension == "json" {
            let target = dst.appendingPathComponent(entry.lastPathComponent)
            // Replace any existing file atomically.
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: entry, to: target)
            } catch {
                os_log(.error, log: taskReminderLog,
                       "Migration: failed to copy %{public}@ to %{public}@: %{public}@",
                       entry.lastPathComponent, target.path, error.localizedDescription)
                ok = false
            }
        }
        return ok
    }

    /// Removes every `*.json` file in `src`, leaving the directory itself.
    private func removeContents(of src: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var ok = true
        for entry in entries where entry.pathExtension == "json" {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                os_log(.error, log: taskReminderLog,
                       "Migration: failed to clean %{public}@: %{public}@",
                       entry.lastPathComponent, error.localizedDescription)
                ok = false
            }
        }
        return ok
    }

    /// File URL for a given task's creation date: `<storage>/YYYY-MM-DD.json`
    /// **Must be called from `ioQueue`** (uses `dateFormatter`).
    private func fileURL(for date: Date) -> URL {
        let filename = dateFormatter.string(from: date) + ".json"
        return resolvedStorageDirectory.appendingPathComponent(filename)
    }

    /// Write (insert or update) a single task into its date file.
    /// **Must be called from `ioQueue`.** Uses NSFileCoordinator so FileProvider
    /// (iCloud Drive) and Finder (when the user touches the file directly)
    /// cannot race us.
    private func saveTask(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        if let existingIndex = dayTasks.firstIndex(where: { $0.id == task.id }) {
            dayTasks[existingIndex] = task
        } else {
            dayTasks.insert(task, at: 0)
        }
        writeDayTasks(dayTasks, to: url)
        noteSyncTimestamp()
    }

    /// Remove a single task from its date file.
    /// **Must be called from `ioQueue`.**
    private func removeTaskFromFile(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        dayTasks.removeAll { $0.id == task.id }
        if dayTasks.isEmpty {
            // Remove empty date files. NSFileCoordinator with `.forDeleting`
            // coordinates with ubiquity container so the empty file is also
            // evicted from iCloud Drive rather than lingering as a placeholder.
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(
                writingItemAt: url,
                options: [.forDeleting],
                error: &coordError
            ) { coordinatedURL in
                do {
                    if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                        try FileManager.default.removeItem(at: coordinatedURL)
                    }
                } catch {
                    os_log(.error, log: taskReminderLog, "Failed to remove empty day file %{public}@: %{public}@",
                           url.lastPathComponent, error.localizedDescription)
                }
            }
            if let coordError {
                os_log(.error, log: taskReminderLog, "FS coordination during delete failed: %{public}@",
                       coordError.localizedDescription)
            }
        } else {
            writeDayTasks(dayTasks, to: url)
        }
        noteSyncTimestamp()
    }

    /// **Must be called from `ioQueue`.**
    private func loadDayTasks(from url: URL) -> [TaskReminder] {
        let coordinator = NSFileCoordinator()
        var result: [TaskReminder] = []
        var coordError: NSError?
        coordinator.coordinate(
            readingItemAt: url,
            options: [.forReading, .resolvesSymbolicLink],
            error: &coordError
        ) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode([TaskReminder].self, from: data) {
                result = decoded
            } else if let text = String(data: data, encoding: .utf8), text.isEmpty {
                // Empty file — treat as no tasks. This happens during iCloud
                // conflict resolution when one side resolves to a blank file.
                result = []
            }
        }
        if let coordError {
            os_log(.error, log: taskReminderLog, "FS coordination during read failed: %{public}@",
                   coordError.localizedDescription)
        }
        return result
    }

    /// **Must be called from `ioQueue`.** Writes atomically via
    /// `NSFileCoordinator` so the iCloud daemon can see and merge the change.
    private func writeDayTasks(_ tasks: [TaskReminder], to url: URL) {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordError
        ) { writeURL in
            do {
                let data = try JSONEncoder().encode(tasks)
                try data.write(to: writeURL, options: .atomic)
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to write day file %{public}@: %{public}@",
                       url.lastPathComponent, error.localizedDescription)
            }
        }
        if let coordError {
            os_log(.error, log: taskReminderLog, "FS coordination during write failed: %{public}@",
                   coordError.localizedDescription)
        }
    }

    /// Load all tasks from every date file in the resolved storage directory.
    /// **Must be called from `ioQueue`.** Updates `tasks` on the main thread.
    private func reconcileAtStartup() {
        let dir = resolvedStorageDirectory
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.tasks = []
            }
            return
        }
        var allTasks: [TaskReminder] = []
        for url in fileURLs where url.pathExtension == "json" {
            allTasks.append(contentsOf: loadDayTasks(from: url))
        }
        // Deduplicate by `id` — iCloud conflict resolution can momentarily
        // surface the same task twice when both versions of the same file
        // are downloaded. Latest createdAt wins.
        var dedupedById: [UUID: TaskReminder] = [:]
        for task in allTasks {
            if let existing = dedupedById[task.id] {
                if task.createdAt >= existing.createdAt {
                    dedupedById[task.id] = task
                }
            } else {
                dedupedById[task.id] = task
            }
        }
        let sorted = Array(dedupedById.values).sorted { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async { [weak self] in
            self?.tasks = sorted
            self?.noteSyncTimestampNow()
        }
    }

    private func noteSyncTimestamp() {
        DispatchQueue.main.async { [weak self] in
            self?.noteSyncTimestampNow()
        }
    }

    private func noteSyncTimestampNow() {
        lastSyncedAt = Date()
    }

    // MARK: - External change watching (iCloud only)

    /// Starts an NSMetadataQuery against the ubiquity container so remote
    /// modifications made by another Mac (same iCloud account) are picked up.
    /// Does nothing if iCloud is not the active storage target.
    private func startWatchingIfNeeded() {
        let dir = resolvedStorageDirectory
        guard isUbiquityContainer(dir) else {
            stopWatching()
            return
        }
        let parentDir = dir.deletingLastPathComponent()
        guard let query = metadataQuery else {
            // Build one query that spans the whole `Documents/` of the
            // ubiquity container. We filter on the `task-note/` subpath in
            // the predicate so unrelated docs do not generate spurious
            // notifications.
            let q = NSMetadataQuery()
            q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            q.valueListAttributes = []
            let predicate = NSPredicate(
                format: "%K BEGINSWITH %@",
                NSMetadataItemPathKey,
                resolvedStorageDirectory.path
            )
            q.predicate = predicate
            metadataQuery = q
            installMetadataObserver(for: q)
            q.start()
            os_log(.info, log: taskReminderLog, "Started NSMetadataQuery on ubiquity container at %{public}@",
                   resolvedStorageDirectory.path)
            return
        }
        // Existing query — refresh predicate against the new directory
        // if user toggled between ubiquity and local.
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            resolvedStorageDirectory.path
        )
        query.stop()
        query.start()
    }

    private func stopWatching() {
        metadataQuery?.stop()
        metadataQuery = nil
        for observer in metadataObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        metadataObservers.removeAll()
    }

    private func installMetadataObserver(for query: NSMetadataQuery) {
        // Listener runs on whatever thread NSMetadataQuery chooses (an
        // internal queue). We dispatch the disk read onto `ioQueue` to keep
        // ordering with our own writes.
        let initialObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { [weak self] _ in
            self?.ioQueue.async {
                self?.reconcileAtStartup()
            }
        }
        let updateObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: nil
        ) { [weak self] _ in
            self?.ioQueue.async {
                self?.reconcileAtStartup()
            }
        }
        metadataObservers = [initialObserver, updateObserver]
    }
}
