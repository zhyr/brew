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
import SwiftUI
import UniformTypeIdentifiers

/// Settings panel for the App Launcher: enables the feature and lets the user
/// assign one of 10 slots to an installed application. Each slot row offers:
///  - The current app icon / name (or "Empty")
///  - A "Choose…" button that opens an .app file picker
///  - A "Clear" button to empty the slot
///
/// Below the slot table, a "Suggested apps" chip row lets the user one-tap
/// assign popular apps (Xcode, Terminal, VS Code, Chrome, etc.) to the next
/// free slot — convenient quick-start path.
struct AppLauncherSettings: View {
    @ObservedObject private var manager = AppLauncherManager.shared
    @Default(.enableAppLauncherFeature) var enableAppLauncherFeature

    @State private var pickerTargetIndex: Int = 0
    @State private var suggestedApps: [AppLauncherManager.SuggestedApp] = []
    @State private var didLoadSuggestions: Bool = false

    private func highlightID(_ title: String) -> String {
        SettingsTab.appLauncher.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableAppLauncherFeature) {
                    Text("Enable App Launcher tab")
                }
                .settingsHighlight(id: highlightID("Enable App Launcher tab"))

                if enableAppLauncherFeature {
                    Button("Open App Launcher tab now") {
                        DynamicIslandViewCoordinator.shared.currentView = .appLauncher
                    }
                    .settingsHighlight(id: highlightID("Open App Launcher tab now"))
                }
            } header: {
                Text("General")
            } footer: {
                Text("Adds a 10-slot quick-launcher tab to the notch. Click a slot in the notch (or use the chooser below) to bind it to an application; clicking a configured slot launches the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enableAppLauncherFeature {
                Section {
                    ForEach(0..<manager.slotCount, id: \.self) { index in
                        slotRow(at: index)
                    }
                } header: {
                    HStack {
                        Text("Slots")
                        Spacer()
                        Text("\(manager.slots.filter { !$0.isEmpty }.count)/\(manager.slotCount) configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if suggestedApps.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("Looking for installed apps…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        suggestedAppsGrid
                    }
                } header: {
                    Text("Suggested apps")
                } footer: {
                    Text("Tap an app to assign it to the next free slot. Apps discovered in /Applications and ~/Applications appear here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if !didLoadSuggestions {
                didLoadSuggestions = true
                // Building the suggested list touches the filesystem and
                // LaunchServices; do it off the main thread to keep the
                // settings scroll smooth.
                DispatchQueue.global(qos: .userInitiated).async {
                    let apps = AppLauncherManager.shared.suggestedApps()
                    DispatchQueue.main.async {
                        suggestedApps = apps
                    }
                }
            }
        }
    }

    // MARK: - Slot row

    @ViewBuilder
    private func slotRow(at index: Int) -> some View {
        let slot = manager.slots[index]
        HStack(spacing: 12) {
            // Slot index badge
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18)

            // Icon — use the manager's cached icon (async off-main load on miss).
            ZStack {
                if slot.isEmpty {
                    Image(systemName: "plus.circle.dashed")
                        .foregroundStyle(.tertiary)
                } else if let icon = manager.icon(for: slot) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)

            // Name
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.isEmpty ? "Empty" : slot.displayName)
                    .font(.body)
                if !slot.isEmpty && !slot.bundleId.isEmpty {
                    Text(slot.bundleId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Actions
            Button("Choose…") { openPicker(for: index) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if !slot.isEmpty {
                Button("Clear") { manager.clearSlot(at: index) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
        }
        .padding(.vertical, 4)
        .settingsHighlight(id: highlightID("Slot \(index + 1)"))
    }

    // MARK: - Suggested apps

    private var suggestedAppsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(suggestedApps) { app in
                Button {
                    assignSuggested(app)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text(app.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func openPicker(for index: Int) {
        pickerTargetIndex = index
        // Shares the single, reusable NSOpenPanel managed by AppLauncherManager.
        // First open pays the ~300–600 ms setup cost; subsequent opens are
        // instant (~10 ms). This panel is identical to what the notch tab uses.
        manager.showAppPicker(
            title: "Choose Application",
            message: "Pick an app to assign to slot \(index + 1).",
            prompt: "Assign"
        ) { [pickerTargetIndex, manager] url in
            guard let url else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            _ = manager.assignApp(at: pickerTargetIndex, appURL: url)
            if needsScope { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func assignSuggested(_ app: AppLauncherManager.SuggestedApp) {
        guard let index = manager.slots.firstIndex(where: { $0.isEmpty }) else {
            // No free slot: overwrite the last one as a fallback.
            let url = URL(fileURLWithPath: app.path)
            _ = manager.assignApp(at: manager.slotCount - 1, appURL: url)
            return
        }
        let url = URL(fileURLWithPath: app.path)
        _ = manager.assignApp(at: index, appURL: url)
    }
}
