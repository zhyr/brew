/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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

import AppKit
import Foundation

/// Detects "what is this AI agent currently doing?" for a single product.
///
/// -----------------------------------------------------------------------
/// ATTRIBUTION
/// -----------------------------------------------------------------------
/// The path conventions and tool-detection heuristics used by every
/// provider below are derived from the open-source project `Al-exporter`
/// (AI Exporter) v2.1.0 by zhyr:
///
///   Repository:  https://github.com/zhyr/Al-exporter
///   Author:      zhyr (https://github.com/zhyr)
///   License:     MIT
///   Key files referenced for path conventions:
///     - core/scan.js              (per-tool PATH_PATTERNS)
///     - core/utils.js             (TOOL_RULES keyword → source mapping)
///     - core/cursor_sqlite.js     (vscdb discovery + inferSourceFromVscdbPath)
///     - core/import.js            (AGENT_PATHS per-source directory list)
///     - adapter/cursor.js,
///       adapter/codex.js          (per-tool config extraction)
///
/// Atoll does NOT redistribute Al-exporter's source. We only reuse the
/// *path conventions* (e.g. `~/Library/Application Support/Trae CN/User/…`,
/// `~/.codex/sessions/`, `~/.workbuddy/sessions/`) as documented in
/// Al-exporter's README and scan.js. The actual probing/reading code
/// below is original Atoll Swift code.
///
/// Why path-convention reuse instead of fresh discovery?
///   Al-exporter has already audited 26+ AI coding tools and codified
///   exactly where each one writes its data on macOS. Reusing that map
///   means Atoll's monitoring lands on the right paths out of the box
///   without us re-doing the audit. The Al-exporter README's "Supported
///   AI Coding Tools" table (lines 32–61) is the authoritative reference
///   for which tool writes where.
protocol AgentActivityProvider {
    /// Stable identifier ("trae", "cursor", "codex", "workbuddy").
    var productID: String { get }
    /// Display name shown in the card header.
    var displayName: String { get }
    /// SF Symbol name for the card icon.
    var iconSystemName: String { get }
    /// Brand color for the card accent.
    var accentColor: AppKit.NSColor { get }
    /// True if the provider's data directory exists on this machine.
    var isInstalled: Bool { get }
    /// True if the product's main process is currently running.
    var isRunning: Bool { get }
    /// Returns the provider's notion of "current task(s)", or nil if it
    /// couldn't be determined. Called on a background queue by the monitor.
    func currentTasks() async -> [AgentTask]
}

/// A single unit of work an agent is currently (or recently was) doing.
struct AgentTask: Identifiable, Equatable {
    /// Stable per-session id from the provider (NOT the SwiftUI identity).
    let sessionID: String
    let productID: String          // "trae" / "cursor" / ...
    let title: String              // First user message / session name, truncated
    let status: Status
    let progressHint: String?      // "Step 3/5", "Editing foo.swift", ...
    let startedAt: Date?
    let lastUpdatedAt: Date?
    let workspacePath: String?     // /Users/.../repo if known

    enum Status: String, Equatable {
        case idle          // Process running but no active session
        case running       // Actively generating / executing a tool
        case awaitingUser  // Waiting for user confirmation
        case completed     // Done (recently)
        case unknown
    }

    /// SwiftUI identity: product + sessionID, so two providers can never collide.
    var id: String { productID + ":" + sessionID }
}

// MARK: - AgentActivityMonitor

/// Singleton that aggregates task state across all known providers.
/// Polled every 5 s when the Agent Activity tab is visible.
final class AgentActivityMonitor: ObservableObject {
    static let shared = AgentActivityMonitor()

    /// All registered providers, in display order.
    let providers: [AgentActivityProvider] = [
        TraeActivityProvider(),
        CursorActivityProvider(),
        CodexActivityProvider(),
        WorkBuddyActivityProvider(),
    ]

    /// Currently observed tasks, flattened across providers. Updated by `poll()`.
    @Published private(set) var tasks: [AgentTask] = []
    /// True while a poll is in flight. UI uses this to show a tiny spinner.
    @Published private(set) var isRefreshing: Bool = false
    /// Per-provider running state, for the header status dot.
    @Published private(set) var runningProviders: Set<String> = []

    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "atoll.agentMonitor", qos: .utility)

    private init() {}

    // MARK: - Polling lifecycle

    func startPolling() {
        guard pollTimer == nil else { return }
        // Kick off an immediate poll so the user doesn't stare at an empty
        // card for 5 s after opening the tab.
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Poll

    /// Ask every provider for its current tasks in parallel, then publish
    /// the merged result on the main actor.
    private func poll() {
        guard !isRefreshing else { return }
        DispatchQueue.main.async { self.isRefreshing = true }

        queue.async { [weak self] in
            guard let self else { return }

            // Use TaskGroup for structured concurrency across providers.
            // Each provider's currentTasks() is async; we await all in parallel.
            Task {
                var running = Set<String>()
                var allTasks: [AgentTask] = []

                await withTaskGroup(of: (String, Bool, [AgentTask]).self) { group in
                    for provider in self.providers {
                        group.addTask {
                            let isRunning = provider.isRunning
                            if isRunning { running.insert(provider.productID) }
                            let tasks = await provider.currentTasks()
                            return (provider.productID, isRunning, tasks)
                        }
                    }
                    for await (pid, isRunning, tasks) in group {
                        if isRunning { running.insert(pid) }
                        allTasks.append(contentsOf: tasks)
                    }
                }

                await MainActor.run {
                    self.runningProviders = running
                    // Sort: running tasks first, then most recently updated.
                    self.tasks = allTasks.sorted { a, b in
                        if a.status == .running && b.status != .running { return true }
                        if a.status != .running && b.status == .running { return false }
                        return (a.lastUpdatedAt ?? .distantPast) > (b.lastUpdatedAt ?? .distantPast)
                    }
                    self.isRefreshing = false
                }
            }
        }
    }
}

// MARK: - Shared helpers

private enum AgentPathUtils {
    /// True if `path` exists (file or directory). Cheap stat.
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// `pgrep -fl`-style process detection by name substring. We use
    /// `NSWorkspace.runningApplications` instead of shelling out to pgrep
    /// because it's faster and doesn't need a fork.
    static func isProcessRunning(_ nameSubstring: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { app in
            guard let name = app.localizedName else { return false }
            return name.localizedCaseInsensitiveContains(nameSubstring)
        }
    }

    /// Most-recently-modified file in a directory (recursive, depth-limited).
    /// Returns nil if the directory is missing or empty. Used to detect
    /// "what session was last touched" without parsing every file.
    static func mostRecentFile(in dir: String, maxDepth: Int = 3,
                               suffix: String? = nil) -> URL? {
        let url = URL(fileURLWithPath: dir)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: URL?
        var bestDate: Date = .distantPast
        var depth = 0
        while let item = enumerator.nextObject() as? URL {
            // Cheap depth check (we don't want to recurse into huge trees).
            let rel = item.path.replacingOccurrences(of: dir + "/", with: "")
            let comps = rel.split(separator: "/")
            if comps.count > maxDepth { continue }
            depth = max(depth, comps.count)
            if let suffix, !item.lastPathComponent.hasSuffix(suffix) { continue }
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let date = values?.contentModificationDate else { continue }
            if date > bestDate {
                bestDate = date
                best = item
            }
        }
        _ = depth
        return best
    }

    /// Read up to `maxBytes` of the head of a file as UTF-8 text. Used to
    /// peek at session JSONL files for the first user message.
    static func peek(_ url: URL, maxBytes: Int = 2048) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Trae (TRAE SOLO CN) provider

/// Monitors Trae CN (also known as TraeCode / "TRAE SOLO CN.app").
///
/// Path conventions per Al-exporter `core/scan.js` lines 69–74:
///   ~/Library/Application Support/Trae CN/User/History
///   ~/Library/Application Support/Trae CN/User/workspaceStorage
///   ~/Library/Application Support/Trae CN/User/globalStorage/state.vscdb
///   ~/.trae
///
/// Active-task signal: mtime of the most recent file under
/// `globalStorage` / `workspaceStorage` / `History`. If the newest
/// modification is < 60 s old and the Trae process is running, we mark
/// the latest session as `.running`. Otherwise `.idle` / `.unknown`.
struct TraeActivityProvider: AgentActivityProvider {
    let productID = "trae"
    let displayName = "Trae"
    let iconSystemName = "sparkles"
    let accentColor = NSColor(red: 0.39, green: 0.51, blue: 0.93, alpha: 1)  // Trae blue-ish

    private var supportDir: String {
        NSHomeDirectory() + "/Library/Application Support/Trae CN/User"
    }
    private var globalStorage: String { supportDir + "/globalStorage" }
    private var workspaceStorage: String { supportDir + "/workspaceStorage" }
    private var historyDir: String { supportDir + "/History" }

    var isInstalled: Bool {
        AgentPathUtils.exists(supportDir) || AgentPathUtils.exists(NSHomeDirectory() + "/.trae")
    }

    var isRunning: Bool {
        AgentPathUtils.isProcessRunning("TRAE SOLO CN") ||
        AgentPathUtils.isProcessRunning("Trae")
    }

    func currentTasks() async -> [AgentTask] {
        guard isInstalled else { return [] }

        // Look for the newest activity signal across the three candidate dirs.
        let candidates = [globalStorage, workspaceStorage, historyDir]
        var bestURL: URL?
        var bestDate: Date = .distantPast
        for dir in candidates where AgentPathUtils.exists(dir) {
            if let url = AgentPathUtils.mostRecentFile(in: dir, maxDepth: 3),
               let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > bestDate {
                bestURL = url
                bestDate = date
            }
        }

        guard let url = bestURL else { return [] }
        let now = Date()
        let age = now.timeIntervalSince(bestDate)
        // < 90 s since last write + process alive => "running".
        let status: AgentTask.Status = (isRunning && age < 90) ? .running
            : (age < 600 ? .idle : .completed)

        // Try to read the first line of the file for a title. Many Trae
        // session files are JSONL; we take the first user-looking message.
        var title = "Trae session"
        if let text = AgentPathUtils.peek(url, maxBytes: 4096) {
            // Grab first JSON line that has role:"user".
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("{"),
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let role = obj["role"] as? String ?? (obj["type"] as? String)
                if role == "user" || role == "human" {
                    if let content = obj["content"] as? String {
                        title = String(content.prefix(80))
                        break
                    }
                    if let parts = obj["content"] as? [[String: Any]] {
                        for p in parts {
                            if let text = p["text"] as? String, !text.isEmpty {
                                title = String(text.prefix(80))
                                break
                            }
                        }
                        if title != "Trae session" { break }
                    }
                }
            }
        }

        return [AgentTask(
            sessionID: url.lastPathComponent,
            productID: productID,
            title: title,
            status: status,
            progressHint: status == .running ? "Editing / chatting" : nil,
            startedAt: bestDate,
            lastUpdatedAt: bestDate,
            workspacePath: nil
        )]
    }
}

// MARK: - Cursor provider

/// Monitors Cursor (Cursor.app).
///
/// Path conventions per Al-exporter `core/scan.js` lines 12–17 and
/// `core/cursor_sqlite.js` lines 69–79:
///   ~/Library/Application Support/Cursor/User/workspaceStorage
///   ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
///   ~/Library/Application Support/Cursor/User/History
///
/// Active-task signal: most recent mtime under workspaceStorage.
struct CursorActivityProvider: AgentActivityProvider {
    let productID = "cursor"
    let displayName = "Cursor"
    let iconSystemName = "cursorarrow.click.square"
    let accentColor = NSColor(red: 0.39, green: 0.85, blue: 0.62, alpha: 1)  // Cursor green

    private var supportDir: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User"
    }
    private var globalStorage: String { supportDir + "/globalStorage" }
    private var workspaceStorage: String { supportDir + "/workspaceStorage" }
    private var historyDir: String { supportDir + "/History" }

    var isInstalled: Bool {
        AgentPathUtils.exists(supportDir) || AgentPathUtils.exists(NSHomeDirectory() + "/.cursor")
    }

    var isRunning: Bool {
        AgentPathUtils.isProcessRunning("Cursor")
    }

    func currentTasks() async -> [AgentTask] {
        guard isInstalled else { return [] }

        let candidates = [workspaceStorage, historyDir, globalStorage]
        var bestURL: URL?
        var bestDate: Date = .distantPast
        for dir in candidates where AgentPathUtils.exists(dir) {
            if let url = AgentPathUtils.mostRecentFile(in: dir, maxDepth: 3),
               let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > bestDate {
                bestURL = url
                bestDate = date
            }
        }
        guard let url = bestURL else { return [] }

        let age = Date().timeIntervalSince(bestDate)
        let status: AgentTask.Status = (isRunning && age < 90) ? .running
            : (age < 600 ? .idle : .completed)

        return [AgentTask(
            sessionID: url.lastPathComponent,
            productID: productID,
            title: "Cursor session",
            status: status,
            progressHint: status == .running ? "Agent active" : nil,
            startedAt: bestDate,
            lastUpdatedAt: bestDate,
            workspacePath: nil
        )]
    }
}

// MARK: - Codex (OpenAI Codex CLI) provider

/// Monitors OpenAI Codex CLI (a.k.a. OpenCode).
///
/// Path conventions per Al-exporter `core/scan.js` lines 27–33 and
/// `core/import.js` lines 19–23:
///   ~/.codex
///   ~/.codex/sessions/<year>/<month>/<day>/...
///   ~/.codex/history.jsonl
///   ~/.codex/state_5.sqlite (queue / thread state)
///
/// Active-task signal: mtime of files under `~/.codex/sessions/`.
struct CodexActivityProvider: AgentActivityProvider {
    let productID = "codex"
    let displayName = "Codex"
    let iconSystemName = "terminal"
    let accentColor = NSColor(red: 0.10, green: 0.70, blue: 0.55, alpha: 1)  // OpenAI teal

    private var codexDir: String { NSHomeDirectory() + "/.codex" }
    private var sessionsDir: String { codexDir + "/sessions" }

    var isInstalled: Bool {
        AgentPathUtils.exists(codexDir) ||
        AgentPathUtils.exists(NSHomeDirectory() + "/.opencode")
    }

    var isRunning: Bool {
        // Codex CLI doesn't show up as a long-lived app in NSWorkspace; check
        // for the `codex` binary in ps output. Use pgrep-equivalent: scan
        // /proc-equivalent on macOS via `ps`.
        // We avoid shelling out by checking most-recent-file mtime instead —
        // if a session file was written in the last 30 s, treat as running.
        guard let url = AgentPathUtils.mostRecentFile(in: sessionsDir, maxDepth: 4) else {
            return false
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let date else { return false }
        return Date().timeIntervalSince(date) < 30
    }

    func currentTasks() async -> [AgentTask] {
        guard isInstalled else { return [] }

        // Codex writes session roll files under sessions/YYYY/MM/DD/.
        guard let url = AgentPathUtils.mostRecentFile(in: sessionsDir, maxDepth: 5),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return []
        }

        let age = Date().timeIntervalSince(date)
        let status: AgentTask.Status = (age < 30) ? .running
            : (age < 600 ? .idle : .completed)

        // Codex session files are JSONL — first line is often a user message.
        var title = "Codex session"
        if let text = AgentPathUtils.peek(url, maxBytes: 4096) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("{"),
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let role = obj["role"] as? String, role == "user",
                   let content = obj["content"] as? String {
                    title = String(content.prefix(80))
                    break
                }
                // Codex also uses { type: "message", role: "user", content: [...] }
                if let role = obj["role"] as? String, role == "user",
                   let parts = obj["content"] as? [[String: Any]] {
                    for p in parts {
                        if let text = p["text"] as? String, !text.isEmpty {
                            title = String(text.prefix(80))
                            break
                        }
                    }
                    if title != "Codex session" { break }
                }
            }
        }

        return [AgentTask(
            sessionID: url.lastPathComponent,
            productID: productID,
            title: title,
            status: status,
            progressHint: status == .running ? "Running command / tool" : nil,
            startedAt: date,
            lastUpdatedAt: date,
            workspacePath: nil
        )]
    }
}

// MARK: - WorkBuddy provider

/// Monitors Tencent WorkBuddy (WorkBuddy.app).
///
/// Path conventions: Al-exporter doesn't list WorkBuddy in its supported
/// tools (it's a Chinese-market product not in the upstream catalogue),
/// but the same pattern applies — WorkBuddy stores everything under
/// `~/.workbuddy/`. We verified the layout on this machine:
///   ~/.workbuddy/sessions/         (session history)
///   ~/.workbuddy/tasks/            (queued / running tasks)
///   ~/.workbuddy/plans/            (long-running plans)
///   ~/.workbuddy/workbuddy.db      (SQLite, primary store)
///
/// Active-task signal: mtime under `~/.workbuddy/sessions/` and
/// `~/.workbuddy/tasks/`.
struct WorkBuddyActivityProvider: AgentActivityProvider {
    let productID = "workbuddy"
    let displayName = "WorkBuddy"
    let iconSystemName = "person.crop.circle.badge.checkmark"
    let accentColor = NSColor(red: 0.94, green: 0.40, blue: 0.40, alpha: 1)  // WB red

    private var dataDir: String { NSHomeDirectory() + "/.workbuddy" }
    private var sessionsDir: String { dataDir + "/sessions" }
    private var tasksDir: String { dataDir + "/tasks" }
    private var plansDir: String { dataDir + "/plans" }

    var isInstalled: Bool {
        AgentPathUtils.exists(dataDir) ||
        AgentPathUtils.exists(NSHomeDirectory() + "/Library/Application Support/WorkBuddy")
    }

    var isRunning: Bool {
        AgentPathUtils.isProcessRunning("WorkBuddy")
    }

    func currentTasks() async -> [AgentTask] {
        guard isInstalled else { return [] }

        // Probe three signal sources in parallel-ish order.
        let candidates = [sessionsDir, tasksDir, plansDir]
        var bestURL: URL?
        var bestDate: Date = .distantPast
        for dir in candidates where AgentPathUtils.exists(dir) {
            if let url = AgentPathUtils.mostRecentFile(in: dir, maxDepth: 3),
               let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > bestDate {
                bestURL = url
                bestDate = date
            }
        }
        guard let url = bestURL else { return [] }

        let age = Date().timeIntervalSince(bestDate)
        let status: AgentTask.Status = (isRunning && age < 90) ? .running
            : (age < 600 ? .idle : .completed)

        return [AgentTask(
            sessionID: url.lastPathComponent,
            productID: productID,
            title: "WorkBuddy task",
            status: status,
            progressHint: status == .running ? "Executing" : nil,
            startedAt: bestDate,
            lastUpdatedAt: bestDate,
            workspacePath: nil
        )]
    }
}
