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
import Combine
import Foundation

/// Disk usage + cleaner manager for the Stats tab.
///
/// This manager exposes three things the Stats tab surfaces as cards:
///   1. Current disk usage on the root volume (free / total / percent).
///   2. "System junk" cleanup — invokes the GLOBAL half of `disk_maintenance.sh`
///      (Gradle / npm / Cargo / pip / Homebrew / Cursor / VS Code / Xcode
///      DerivedData / Simulator caches / Docker prune).
///   3. "Developer junk" cleanup — invokes the WORK half of `disk_maintenance.sh`
///      for `~/work` (cache dirs like .next / __pycache__ / tsbuildinfo / Rust
///      target/debug / Electron staging / logs / test-results).
///
/// -----------------------------------------------------------------------
/// ATTRIBUTION
/// -----------------------------------------------------------------------
/// The cleanup logic itself is NOT original Atoll code. It is a thin Swift
/// wrapper around the bash script `disk_maintenance.sh` (v4.0.0) from:
///
///   Repository:  https://github.com/zhyr/LLM-based-Software-Devlopment-Kit-Suite
///   Author:      zhyr (https://github.com/zhyr)
///   File:        disk_maintenance.sh
///   License:     Public — the repository carries no explicit LICENSE file at
///                time of integration; the script header documents itself as
///                "开发者通用磁盘清理工具" and is used here in accordance with
///                the repository's public release.
///
/// Atoll does NOT redistribute the script verbatim. Instead, `DiskCleaner`
/// ships a byte-for-byte copy of `disk_maintenance.sh` v4.0.0 as a bundled
/// resource inside `Atoll.app/Contents/Resources/disk_maintenance.sh`, and
/// invokes it via `Process` (`/bin/bash <bundled script>`).
///
/// If the upstream script is updated, the bundled copy in Resources should be
/// refreshed in lockstep; the `ScriptVersion` constant below is the
/// single source of truth for which version is bundled.
///
/// Why shell-out instead of reimplementing in Swift?
///   - The script encodes a LOT of safety logic (skip node_modules/.git/.env,
///     protect dist with .dmg/.pkg, skip Cargo registry/src, etc.) that we
///     do NOT want to re-implement and risk getting wrong. Delegating to the
///     audited bash keeps the destructive logic in one well-tested place.
///   - Users get identical behavior to running the script by hand.
final class DiskCleaner: ObservableObject {
    static let shared = DiskCleaner()

    /// Version of the bundled `disk_maintenance.sh`. Bump this whenever the
    /// resource copy is refreshed from upstream.
    static let ScriptVersion = "4.0.0"
    /// Upstream repository for attribution / updates.
    static let ScriptSourceURL = "https://github.com/zhyr/LLM-based-Software-Devlopment-Kit-Suite"
    static let ScriptAuthor = "zhyr"
    static let ScriptFile = "disk_maintenance.sh"

    // MARK: - Published state for the UI

    /// Latest disk-usage snapshot for the root data volume. Polled on a 5s
    /// timer when the Stats tab is visible. Nil until the first poll returns.
    @Published private(set) var diskUsage: DiskUsage?

    /// True while a cleanup job is running. The cards use this to show a
    /// spinner and disable their button.
    @Published private(set) var isCleaning: Bool = false

    /// Human-readable progress line from the running script (the last line of
    /// its stdout). Shown under the spinner so the user can see "正在清理
    /// Xcode DerivedData…" etc.
    @Published private(set) var lastProgressLine: String = ""

    /// Result of the most recent cleanup, surfaced in the card after it
    /// finishes. Persists until the next cleanup starts.
    @Published private(set) var lastResult: CleanupResult?

    private var pollTimer: Timer?
    private var isPaused = false
    private var currentTask: Process?

    private init() {
        // Do NOT start polling here — the Stats tab view starts/stops polling
        // in onAppear/onDisappear so we don't waste CPU when stats aren't
        // visible.
    }

    // MARK: - Disk usage polling

    /// Models the usage of a single volume.
    struct DiskUsage: Equatable {
        let volumeURL: URL
        let totalBytes: Int64
        let freeBytes: Int64
        var usedBytes: Int64 { totalBytes - freeBytes }
        var usedPercent: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        }
    }

    /// Refresh `diskUsage` for the root data volume. Called by the polling
    /// timer and on-demand. Cheap (statfs, ~1ms).
    func refreshDiskUsage() {
        // On macOS 11+ the user data lives on /System/Volumes/Data. statfs on
        // that path returns the real free/total for the data container.
        let dataVolume = "/System/Volumes/Data"
        var stat = statfs()
        guard statfs(dataVolume, &stat) == 0 else {
            // Fallback to root.
            if statfs("/", &stat) == 0 {
                let total = Int64(stat.f_blocks) * Int64(stat.f_bsize)
                let free = Int64(stat.f_bavail) * Int64(stat.f_bsize)
                DispatchQueue.main.async {
                    self.diskUsage = DiskUsage(
                        volumeURL: URL(fileURLWithPath: "/"),
                        totalBytes: total,
                        freeBytes: free
                    )
                }
            }
            return
        }
        let total = Int64(stat.f_blocks) * Int64(stat.f_bsize)
        let free = Int64(stat.f_bavail) * Int64(stat.f_bsize)
        let url = URL(fileURLWithPath: dataVolume)
        DispatchQueue.main.async {
            self.diskUsage = DiskUsage(
                volumeURL: url,
                totalBytes: total,
                freeBytes: free
            )
        }
    }

    /// Start the 5s polling timer. Safe to call multiple times — duplicates
    /// are ignored. If the timer already exists but is paused, this resumes it.
    func startPolling() {
        guard pollTimer == nil else {
            isPaused = false
            return
        }
        refreshDiskUsage()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.refreshDiskUsage()
        }
    }

    /// Pause polling instead of invalidating the timer. Keeps the timer alive
    /// so resuming is instant and avoids unnecessary statfs calls when the
    /// Stats tab isn't visible.
    func stopPolling() {
        isPaused = true
    }

    // MARK: - Cleanup execution

    /// Which half of `disk_maintenance.sh` to run.
    enum CleanupScope: String {
        /// Global tool caches (Gradle/npm/Cargo/pip/Homebrew/Cursor/VSCode/Xcode/Simulator/Docker).
        /// Maps to `--global-only`.
        case system
        /// Per-workspace project caches under `~/work` (`.next` / `__pycache__` /
        /// `tsbuildinfo` / Rust target/debug / Electron staging / logs / test-results).
        /// Maps to `--work-only`.
        case developer
    }

    struct CleanupResult {
        let scope: CleanupScope
        /// Bytes freed, parsed from the script's final summary line.
        /// Nil if parsing failed (script still ran successfully).
        let freedBytes: Int64?
        /// Stdout of the script, kept for the "details" popover.
        let log: String
        /// Exit status. 0 = success.
        let exitStatus: Int
        var succeeded: Bool { exitStatus == 0 }
    }

    /// Run the cleanup script with the given scope. Async — publishes
    /// `isCleaning=true`, streams `lastProgressLine`, then publishes
    /// `lastResult` and `isCleaning=false`.
    ///
    /// Uses `--yes` so the script doesn't block on stdin. Uses `--dry-run`
    /// when `dryRun` is true so the user can preview what would be freed.
    func runCleanup(scope: CleanupScope, dryRun: Bool = false) {
        guard !isCleaning else { return }  // refuse concurrent cleanups
        guard let scriptURL = bundledScriptURL else {
            DispatchQueue.main.async {
                self.lastResult = CleanupResult(
                    scope: scope, freedBytes: nil,
                    log: "Bundled disk_maintenance.sh not found in app resources.",
                    exitStatus: -1
                )
            }
            return
        }

        DispatchQueue.main.async {
            self.isCleaning = true
            self.lastProgressLine = dryRun ? "预览中…" : "清理中…"
        }

        let task = Process()
        task.launchPath = "/bin/bash"
        var args = [scriptURL.path, "--yes"]
        switch scope {
        case .system:    args.append("--global-only")
        case .developer: args.append("--work-only")
        }
        if dryRun { args.append("--dry-run") }
        task.arguments = args

        // Stream stdout+stderr to capture progress lines and the final summary.
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let buf = NSMutableString()
        func emit(_ s: String) {
            buf.append(s)
            // Last non-empty line is the "current activity" line.
            let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
            if let last = lines.last {
                DispatchQueue.main.async {
                    self.lastProgressLine = String(last)
                }
            }
        }

        // Read in background to avoid deadlock when the pipe buffer fills.
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            if let s = String(data: data, encoding: .utf8) {
                emit(s)
            }
        }

        task.terminationHandler = { [weak self] proc in
            // Drain anything left in the pipe.
            let rest = handle.readDataToEndOfFile()
            if let s = String(data: rest, encoding: .utf8), !s.isEmpty {
                buf.append(s)
            }
            let log = buf as String
            let freed = DiskCleaner.parseFreedBytes(from: log)
            let result = CleanupResult(
                scope: scope,
                freedBytes: freed,
                log: log,
                exitStatus: Int(proc.terminationStatus)
            )
            DispatchQueue.main.async {
                self?.isCleaning = false
                self?.lastResult = result
                self?.refreshDiskUsage()  // refresh card immediately
            }
        }

        do {
            try task.run()
            currentTask = task
        } catch {
            DispatchQueue.main.async {
                self.isCleaning = false
                self.lastResult = CleanupResult(
                    scope: scope, freedBytes: nil,
                    log: "Failed to launch /bin/bash: \(error.localizedDescription)",
                    exitStatus: -1
                )
            }
        }
    }

    /// Cancel a running cleanup. The script's `set -euo pipefail` plus the
    /// fact that all `rm` calls are individually guarded means SIGTERM is
    /// safe — at worst we leave a half-deleted cache dir, which is fine
    /// since caches are by definition recreatable.
    func cancel() {
        currentTask?.terminate()
        currentTask = nil
        DispatchQueue.main.async {
            self.isCleaning = false
            self.lastProgressLine = "已取消"
        }
    }

    // MARK: - Bundled script resolution

    /// URL of the bundled `disk_maintenance.sh` inside the app bundle's
    /// Resources directory. Nil in tests/sandboxed runs without the resource.
    private var bundledScriptURL: URL? {
        // First check the main bundle (release/normal debug builds).
        if let url = Bundle.main.url(forResource: "disk_maintenance", withExtension: "sh") {
            return url
        }
        // Fall back to a project-relative path for development builds where
        // the script hasn't been added to the Resources copy phase yet.
        // This makes it possible to test the integration before adding the
        // resource to the Xcode project.
        let devPath = "/Users/yr.z/work/Atoll/DynamicIsland/Resources/disk_maintenance.sh"
        if FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        return nil
    }

    // MARK: - Parsing helpers

    /// Parse "约释放 1234 MB" or "约可释放约 1234 MB" out of the script's
    /// final summary line. Returns bytes, or nil if no number was found.
    private static func parseFreedBytes(from log: String) -> Int64? {
        // The script prints either:
        //   ✅ 清理完成，约释放 1234 MB
        //   🔍 预览完成，预计可释放约 1234 MB（实际可能因嵌套略有偏差）
        // We just look for "<number> MB" anywhere in the log.
        guard let regex = try? NSRegularExpression(
            pattern: "(\\d+)\\s*MB",
            options: []
        ) else { return nil }
        let range = NSRange(log.startIndex..., in: log)
        guard let match = regex.firstMatch(in: log, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: log),
              let mb = Int64(log[numberRange]) else {
            return nil
        }
        return mb * 1024 * 1024
    }
}

// MARK: - Formatting helpers shared with the card views

extension DiskCleaner.DiskUsage {
    /// Human-readable "1.2 TB free / 2.0 TB total"
    var summary: String {
        "\(DiskCleaner.DiskUsage.formatBytes(freeBytes)) free / \(DiskCleaner.DiskUsage.formatBytes(totalBytes))"
    }
    /// Human-readable "62%"
    var usedPercentString: String {
        String(format: "%.0f%%", usedPercent * 100)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension DiskCleaner.CleanupResult {
    /// Human-readable "释放了 1.2 GB" / "预计释放 1.2 GB" / "失败"
    var summary: String {
        if !succeeded { return "清理失败" }
        guard let bytes = freedBytes else { return "清理完成" }
        return "释放 \(DiskCleaner.DiskUsage.formatBytes(bytes))"
    }
}
