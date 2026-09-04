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

/// The notch tab view for the App Launcher: a grid of 10 slots.
///
/// Each slot shows the app icon (or a "+" placeholder when empty). Tapping a
/// configured slot launches the app; tapping an empty slot opens the system
/// file picker so the user can choose an .app to bind to it. Long-press / right
/// click on a configured slot offers "Remove" and "Reveal in Finder".
struct NotchAppLauncherView: View {
    @ObservedObject private var manager = AppLauncherManager.shared
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared

    @State private var launchingIndex: Int? = nil
    @State private var pickerTargetIndex: Int = 0
    @State private var showRemoveConfirm: Int? = nil

    // 5 columns × 2 rows = 10 slots, fits the notch aspect ratio nicely.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 12) {
            header

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<manager.slotCount, id: \.self) { index in
                    slotView(at: index)
                }
            }
            .padding(.horizontal, 8)

            if manager.slots.allSatisfy({ $0.isEmpty }) {
                emptyState
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(backgroundGradient)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("App Launcher")
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
            Text("\(manager.slots.filter { !$0.isEmpty }.count)/\(manager.slotCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Slot

    @ViewBuilder
    private func slotView(at index: Int) -> some View {
        let slot = manager.slots[index]
        let isLaunching = launchingIndex == index

        ZStack {
            if slot.isEmpty {
                emptySlotContent(index: index)
            } else {
                filledSlotContent(slot: slot, index: index, isLaunching: isLaunching)
            }
        }
        .frame(width: 46, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(slot.isEmpty ? Color.gray.opacity(0.10) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    slot.isEmpty ? Color.gray.opacity(0.25) : Color.blue.opacity(0.35),
                    lineWidth: slot.isEmpty ? 1 : 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            handleTap(at: index)
        }
        .contextMenu {
            if !slot.isEmpty {
                Button("Launch \(slot.displayName)") { launch(at: index) }
                Button("Reveal in Finder") { revealInFinder(slot: slot) }
                Divider()
                Button("Remove from slot", role: .destructive) {
                    manager.clearSlot(at: index)
                }
            } else {
                Button("Choose app…") { openPicker(for: index) }
            }
        }
        .help(slot.isEmpty ? "Click to choose an app" : "Launch \(slot.displayName)")
    }

    @ViewBuilder
    private func emptySlotContent(index: Int) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func filledSlotContent(slot: AppLauncherSlot, index: Int, isLaunching: Bool) -> some View {
        if isLaunching {
            ProgressView()
                .scaleEffect(0.7)
        } else if let symbol = slot.customIcon, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
        } else if let icon = manager.icon(for: slot) {
            // manager.icon returns nil on cache miss (enqueues async load) —
            // we fall through to the letter tile below, which paints instantly.
            // When the icon is ready, manager.objectWillChange triggers a
            // redraw and we end up in this branch on the next pass.
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        } else {
            // Fallback: first letter of the app name (paints in ~0ms, no disk I/O).
            // This is the fast path after Assign while the async icon load is
            // still in flight.
            Text(String(slot.displayName.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No apps configured")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Click any slot to pick an app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.04), Color.purple.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Actions

    private func handleTap(at index: Int) {
        let slot = manager.slots[index]
        if slot.isEmpty {
            openPicker(for: index)
        } else {
            launch(at: index)
        }
    }

    private func openPicker(for index: Int) {
        pickerTargetIndex = index
        // Uses the manager's single, reusable NSOpenPanel. The panel is
        // lazily created on the first call (~300–600 ms) and then re-used for
        // every subsequent open — so the second and later "Choose…" clicks
        // open instantly.
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

    private func launch(at index: Int) {
        launchingIndex = index
        AppLauncherManager.shared.launch(at: index)
        // Clear the spinner shortly after; we don't get a launch callback synchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if launchingIndex == index { launchingIndex = nil }
        }
    }

    private func revealInFinder(slot: AppLauncherSlot) {
        guard !slot.appPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.appPath)])
    }

}
