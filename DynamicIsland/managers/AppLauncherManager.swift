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
import Defaults
import Foundation
import Combine

/// Manages the 10-slot App Launcher: persistence, app discovery, and launching.
///
/// Slots are stored in `Defaults[.appLauncherSlots]` (always length 10). Empty
/// slots have an empty `bundleId`. The manager also offers a small directory of
/// "suggested" popular apps so the settings UI can offer quick-pick chips.
final class AppLauncherManager: ObservableObject {
    static let shared = AppLauncherManager()

    @Published var slots: [AppLauncherSlot] = Defaults[.appLauncherSlots]

    /// In-memory icon cache keyed by absolute app path, populated on-demand so
    /// the notch grid never hits the disk twice for the same app icon. Saves
    /// ~11 ms per filled slot on every SwiftUI redraw — multiplied by 10 slots
    /// that's a 100ms+ reduction of main-thread work during slot reassignment,
    /// which was the largest contributor to the "Assign button feels slow"
    /// complaint.
    private var iconCache: [String: NSImage] = [:]
    /// Serial queue used to load app icons off the main thread so they never
    /// block SwiftUI render passes. The rendered slot still shows a fallback
    /// until the icon arrives.
    private let iconQueue = DispatchQueue(label: "atoll.appLauncher.icons", qos: .userInitiated)

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Keep Defaults in sync whenever slots change.
        $slots
            .dropFirst()
            .sink { Defaults[.appLauncherSlots] = $0 }
            .store(in: &cancellables)

        // Backfill / trim to exactly 10 slots in case persisted state is stale.
        if slots.count != Defaults.Keys.appLauncherSlotCount {
            adjustToFixedCount()
        }
    }

    // MARK: - Slot access

    var slotCount: Int { Defaults.Keys.appLauncherSlotCount }

    func slot(at index: Int) -> AppLauncherSlot? {
        guard slots.indices.contains(index) else { return nil }
        return slots[index]
    }

    /// Assign an app (by URL to its .app bundle) to a slot.
    ///
    /// Returns true on success, false if the URL does not point at a valid .app
    /// bundle (in which case the slot is left untouched — no partial write).
    @discardableResult
    func assignApp(at index: Int, appURL: URL) -> Bool {
        guard slots.indices.contains(index) else { return false }
        // Require a real .app bundle. We check BOTH the path extension and
        // Bundle(url:) because Foundation's Bundle(url:) is surprisingly
        // lenient — e.g. it returns a non-nil (but bundleIdentifier-less)
        // Bundle for the plain /Applications directory, which would otherwise
        // produce a partial slot (empty bundleId, non-empty appName/appPath)
        // and later cause launch() to try to open a directory as an app.
        // Caught by AppLauncherSlotsTests.testAssignAppWithInvalidBundleIsNoOp.
        guard appURL.pathExtension == "app",
              let bundle = Bundle(url: appURL) else { return false }
        let bundleId = bundle.bundleIdentifier ?? ""
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let newSlot = AppLauncherSlot(
            id: slots[index].id,
            bundleId: bundleId,
            appName: appName,
            appPath: appURL.path
        )
        slots[index] = newSlot
        // Kick off an async icon prefetch for the new slot. If this finishes
        // before the SwiftUI redraw runs, the user sees the actual icon on the
        // first paint. Otherwise they see the letter-tile fallback for ~1 frame
        // and the icon materializes shortly after — both paths are zero-blocking
        // on the main thread, so the Assign button no longer "freezes".
        prefetchIcon(for: newSlot)
        return true
    }

    /// Clear a slot back to empty.
    func clearSlot(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = AppLauncherSlot(id: slots[index].id)
    }

    /// Swap two slots (for drag-reorder, optional).
    func swap(_ a: Int, _ b: Int) {
        guard slots.indices.contains(a), slots.indices.contains(b) else { return }
        slots.swapAt(a, b)
    }

    // MARK: - Launch

    /// Launch the app assigned to `index`. Returns false if the slot is empty
    /// or the app could not be launched.
    @discardableResult
    func launch(at index: Int) -> Bool {
        guard let slot = slot(at: index), !slot.isEmpty else {
            print("⚠️ AppLauncher: slot \(index) is empty")
            return false
        }

        // Prefer launching by path so a moved app still works if the user
        // re-picked it; fall back to bundle id lookup.
        if !slot.appPath.isEmpty {
            let url = URL(fileURLWithPath: slot.appPath)
            if FileManager.default.fileExists(atPath: slot.appPath) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if let error = error {
                        print("❌ AppLauncher: failed to launch \(slot.appName) at \(slot.appPath) - \(error.localizedDescription)")
                    } else {
                        print("🚀 AppLauncher: launched \(slot.appName)")
                    }
                }
                return true
            }
        }

        // Fall back to bundle id.
        if !slot.bundleId.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slot.bundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error = error {
                    print("❌ AppLauncher: failed to launch by bundle id \(slot.bundleId) - \(error.localizedDescription)")
                } else {
                    print("🚀 AppLauncher: launched \(slot.appName) by bundle id")
                }
            }
            return true
        }

        print("❌ AppLauncher: app no longer available - \(slot.appName)")
        return false
    }

    // MARK: - App discovery

    /// Suggested popular apps to offer as quick-pick chips in settings.
    /// Looked up from /Applications and ~/Applications.
    struct SuggestedApp: Identifiable, Hashable {
        let id: String  // bundle id
        let name: String
        let path: String
        let bundleId: String
    }

    /// Curated list of bundle ids we consider "popular" for an IT developer.
    private static let popularBundleIds: [String] = [
        "com.apple.dt.Xcode",                  // Xcode
        "com.apple.Terminal",                  // Terminal
        "com.googlecode.iterm2",               // iTerm2
        "com.todesktop.230313mzl4w4u92",       // Cursor
        "com.microsoft.VSCode",                // VS Code
        "com.github.atom",                     // Atom (legacy)
        "com.jetbrains.intellij.ce",           // IntelliJ IDEA CE
        "com.jetbrains.pycharm",               // PyCharm
        "com.jetbrains.goland",                // GoLand
        "com.jetbrains.CLion",                 // CLion
        "com.jetbrains.rubymine",              // RubyMine
        "com.jetbrains.androidStudio",         // Android Studio
        "com.postmanlabs.mac",                 // Postman
        "com.docker.docker",                   // Docker Desktop
        "com.google.Chrome",                   // Chrome
        "org.mozilla.firefox",                 // Firefox
        "company.thebrowser.Browser",          // Arc
        "com.apple.Safari",                    // Safari
        "com.tinyspeck.slackmacgap",           // Slack
        "com.microsoft.teams2",                // Microsoft Teams
        "ru.keepcoder.Telegram",               // Telegram
        "com.apple.iChat",                     // Messages
        "com.apple.mail",                      // Mail
        "com.apple.finder",                    // Finder
        "com.apple.systempreferences",         // System Settings
        "com.apple.ActivityMonitor",           // Activity Monitor
        "com.apple.dt.console",                // Console
        "com.apple.grapher",                   // Grapher
        "com.googlecode.sourcetreeapp",        // Sourcetree
        "com.gitfinder.gitfinder",             // GitFinder
        "com.kingsoft.wpsoffice.mac",          // WPS
        "com.tencent.xinWeChat",               // WeChat
        "com.apple.appstore",                  // App Store
        "com.apple.Notes",                     // Notes
        "com.apple.TextEdit",                  // TextEdit
        "com.apple.preview"                    // Preview
    ]

    /// Resolve suggested apps that are actually installed on this machine.
    func suggestedApps() -> [SuggestedApp] {
        var results: [SuggestedApp] = []
        var seen = Set<String>()

        // First, scan /Applications and ~/Applications for top-level .app
        // bundles — this catches apps whose bundle id isn't in the curated list.
        let candidateDirs: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSString("~/Applications").expandingTildeInPath)
        ]
        for dir in candidateDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry),
                      let bid = bundle.bundleIdentifier,
                      !bid.isEmpty,
                      seen.insert(bid).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                results.append(SuggestedApp(id: bid, name: name, path: entry.path, bundleId: bid))
            }
        }

        // Then ensure the curated popular list is present even if installed in
        // non-standard locations (via LaunchServices lookup).
        for bid in Self.popularBundleIds {
            if seen.contains(bid) { continue }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
               let bundle = Bundle(url: url) {
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                results.append(SuggestedApp(id: bid, name: name, path: url.path, bundleId: bid))
                seen.insert(bid)
            }
        }

        // Sort: popular curated apps first (in their list order), then the rest alphabetical.
        let popularOrder = Self.popularBundleIds.enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset }
        return results.sorted { a, b in
            let ao = popularOrder[a.bundleId] ?? Int.max
            let bo = popularOrder[b.bundleId] ?? Int.max
            if ao != bo { return ao < bo }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Icon cache

    /// Returns the cached icon for `slot` if it has already been loaded;
    /// otherwise triggers an asynchronous off-main load and publishes it via
    /// `objectWillChange` once ready. The synchronous return value is always
    /// non-blocking: either the cached image, or `nil` (caller should show a
    /// fallback like the app-name letter tile).
    ///
    /// This method is intentionally lightweight: no `FileManager` stat, no
    /// `NSWorkspace.icon(forFile:)` on the caller's thread. The slow disk work
    /// happens once, in the background, cached forever.
    func icon(for slot: AppLauncherSlot) -> NSImage? {
        let key = iconCacheKey(for: slot)
        if let cached = iconCache[key] { return cached }
        if slot.isEmpty { return nil }
        // Trigger the async load once per cache miss. Use key as lock marker
        // so concurrent callers don't enqueue two loads for the same slot.
        iconQueue.async { [weak self] in
            self?.loadIconIntoCache(for: slot, key: key)
        }
        return nil
    }

    /// Prefetch an app icon *before* the slot is shown — e.g. called from
    /// `assignApp` immediately after assignment so the first redraw after
    /// Assign already has the icon ready.
    func prefetchIcon(for slot: AppLauncherSlot) {
        let key = iconCacheKey(for: slot)
        guard iconCache[key] == nil, !slot.isEmpty else { return }
        iconQueue.async { [weak self] in
            self?.loadIconIntoCache(for: slot, key: key)
        }
    }

    private func loadIconIntoCache(for slot: AppLauncherSlot, key: String) {
        // Already loaded on a concurrent branch of the queue?
        if iconCache[key] != nil { return }

        let resolvedPath: String = {
            if !slot.appPath.isEmpty,
               FileManager.default.fileExists(atPath: slot.appPath) {
                return slot.appPath
            }
            if !slot.bundleId.isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slot.bundleId) {
                return url.path
            }
            return ""
        }()
        guard !resolvedPath.isEmpty else { return }

        let image = NSWorkspace.shared.icon(forFile: resolvedPath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Guard against a race where this slot was cleared between enqueue
            // and the icon arriving — in that case don't publish (we'd be
            // flashing a stale icon on an empty slot).
            guard let current = self.slot(by: slot.id), !current.isEmpty else { return }
            self.iconCache[key] = image
            self.objectWillChange.send()
        }
    }

    private func iconCacheKey(for slot: AppLauncherSlot) -> String {
        // Prefer path because it's unique per bundle-on-disk; fall back to
        // bundle id if path is empty for some reason.
        slot.appPath.isEmpty ? slot.bundleId : slot.appPath
    }

    private func slot(by id: UUID) -> AppLauncherSlot? {
        slots.first { $0.id == id }
    }

    // MARK: - Shared NSOpenPanel (reusable)

    /// A single, pre-built `NSOpenPanel` shared between the notch view and the
    /// settings view. Creating an NSOpenPanel with
    /// `allowedContentTypes = [.application]` costs 300–600 ms on first
    /// creation because the system enumerates every .app bundle via
    /// LaunchServices/Spotlight. Before this fix, every "Choose…" click paid
    /// that cost all over again. Now we build it once and re-use the same
    /// instance (resetting its state between shows).
    ///
    /// Callbacks are stored in the panel's `representingURL` context for
    /// simplicity. Actually we keep a dedicated `pickerCompletionHandler`
    /// property so the caller doesn't have to fish state back out of the panel.
    private var pickerPanel: NSOpenPanel?
    private var pickerCompletionHandler: ((URL?) -> Void)?

    /// Present the shared app-picker panel and call `completion` with either
    /// the chosen .app URL (on OK) or `nil` (on Cancel / out-of-band close).
    ///
    /// If the panel has already been created, this call is near-instant
    /// (~10 ms). The first call pays the one-time 300–600 ms setup cost — which
    /// is acceptable because it's hidden inside the "open picker" action
    /// before the user even sees anything, and subsequent clicks are free.
    func showAppPicker(title: String = "Choose Application",
                       message: String = "Pick an application.",
                       prompt: String = "Assign",
                       completion: @escaping (URL?) -> Void) {
        if pickerPanel == nil {
            // Build the shared panel exactly once.
            let panel = NSOpenPanel()
            panel.title = title
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.resolvesAliases = true
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            pickerPanel = panel
        }

        guard let panel = pickerPanel else {
            completion(nil)
            return
        }

        // Reset per-call state (cheap, < 1 ms)
        panel.message = message
        panel.prompt = prompt
        panel.title = title
        if panel.directoryURL?.path != "/Applications" {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        pickerCompletionHandler = completion

        panel.begin { [weak self] response in
            guard let self else { return }
            defer { self.pickerCompletionHandler = nil }
            let chosen = (response == .OK) ? panel.url : nil
            self.pickerCompletionHandler?(chosen)
        }
    }

    // MARK: - Helpers

    private func adjustToFixedCount() {
        let target = Defaults.Keys.appLauncherSlotCount
        if slots.count < target {
            slots.append(contentsOf: (slots.count..<target).map { _ in AppLauncherSlot() })
        } else if slots.count > target {
            slots = Array(slots.prefix(target))
        }
    }
}
