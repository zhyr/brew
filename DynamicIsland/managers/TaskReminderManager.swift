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

/// Singleton manager for task reminders.
///
/// Tasks are persisted as JSON files under
/// `~/Documents/brew/task-note/`, one file per calendar day
/// (e.g. `2026-09-05.json`). Each file contains the array of tasks created
/// on that day. Marking a task complete only flips the `completed` flag in
/// the file — it never deletes the record. Data is only removed when the
/// user explicitly deletes a single task.
///
/// Threading model:
/// - `tasks` (the `@Published` array) is always read and written on the main
///   thread so SwiftUI updates are consistent.
/// - All disk I/O (load/save/delete) runs on `ioQueue`, a serial background
///   queue, so it never blocks the main thread. `dateFormatter` is only
///   touched from `ioQueue`, which makes its non-thread-safe nature safe.
final class TaskReminderManager: ObservableObject {
    static let shared = TaskReminderManager()

    @Published private(set) var tasks: [TaskReminder] = []

    /// `~/Documents/brew/task-note/`
    private let storageDirectory: URL

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

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageDirectory = docs.appendingPathComponent("brew/task-note", isDirectory: true)
        ensureDirectoryExists()
        migrateFromUserDefaultsIfNeeded()
        // Load from disk on the background queue; `tasks` starts empty and
        // populates once the read completes. UI shows empty state briefly.
        ioQueue.async { [weak self] in
            self?.load()
        }
    }

    /// One-time migration: tasks were previously stored under the UserDefaults
    /// key `BrewTaskReminders`. Move them into date-archived JSON files so all
    /// data lives in `~/Documents/brew/task-note/`.
    ///
    /// The read from UserDefaults happens on the caller's thread (init); the
    /// file writes are dispatched to `ioQueue` so `dateFormatter` is only
    /// ever touched there.
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

    // MARK: - CRUD

    /// Add a new task from text. Whitespace-only strings are ignored.
    /// The task is written to today's date file.
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

    // MARK: - Persistence (all on ioQueue)

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: storageDirectory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: storageDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to create storage directory at %{public}@: %{public}@",
                       storageDirectory.path, error.localizedDescription)
            }
        }
    }

    /// File URL for a given task's creation date: `~/Documents/brew/task-note/YYYY-MM-DD.json`
    /// **Must be called from `ioQueue`** (uses `dateFormatter`).
    private func fileURL(for date: Date) -> URL {
        let filename = dateFormatter.string(from: date) + ".json"
        return storageDirectory.appendingPathComponent(filename)
    }

    /// Write (insert or update) a single task into its date file.
    /// **Must be called from `ioQueue`.**
    private func saveTask(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        if let existingIndex = dayTasks.firstIndex(where: { $0.id == task.id }) {
            dayTasks[existingIndex] = task
        } else {
            dayTasks.insert(task, at: 0)
        }
        writeDayTasks(dayTasks, to: url)
    }

    /// Remove a single task from its date file.
    /// **Must be called from `ioQueue`.**
    private func removeTaskFromFile(_ task: TaskReminder) {
        let url = fileURL(for: task.createdAt)
        var dayTasks = loadDayTasks(from: url)
        dayTasks.removeAll { $0.id == task.id }
        if dayTasks.isEmpty {
            // Remove empty date files to keep the directory clean.
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                os_log(.error, log: taskReminderLog, "Failed to remove empty day file %{public}@: %{public}@",
                       url.lastPathComponent, error.localizedDescription)
            }
        } else {
            writeDayTasks(dayTasks, to: url)
        }
    }

    /// **Must be called from `ioQueue`.**
    private func loadDayTasks(from url: URL) -> [TaskReminder] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TaskReminder].self, from: data) else {
            return []
        }
        return decoded
    }

    /// **Must be called from `ioQueue`.**
    private func writeDayTasks(_ tasks: [TaskReminder], to url: URL) {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log(.error, log: taskReminderLog, "Failed to write day file %{public}@: %{public}@",
                   url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Load all tasks from every date file in the storage directory.
    /// **Must be called from `ioQueue`.** Updates `tasks` on the main thread.
    private func load() {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var allTasks: [TaskReminder] = []
        for url in fileURLs where url.pathExtension == "json" {
            allTasks.append(contentsOf: loadDayTasks(from: url))
        }
        let sorted = allTasks.sorted { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async { [weak self] in
            self?.tasks = sorted
        }
    }
}
