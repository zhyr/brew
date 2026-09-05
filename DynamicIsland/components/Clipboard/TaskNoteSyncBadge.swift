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

import SwiftUI

/// Status badge that mirrors `TaskReminderManager.shared.iCloudSyncState`.
/// Lives in the notch header next to the TaskNote button so the user can
/// tell at a glance whether tasks are reaching iCloud Drive and picking up
/// changes from other Macs.
struct TaskNoteSyncBadge: View {
    @ObservedObject private var manager = TaskReminderManager.shared

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .help(manager.iCloudSyncState.description)
    }

    private var iconName: String {
        switch manager.iCloudSyncState {
        case .signedIn:         return "cloud.fill"
        case .signedOut:        return "cloud.slash"
        case .temporarilyLocal: return "icloud.slash"
        case .downloadingFiles: return "arrow.down.circle"
        case .unknown:          return "cloud"
        }
    }

    private var tint: Color {
        switch manager.iCloudSyncState {
        case .signedIn:         return .green
        case .signedOut:        return .secondary
        case .temporarilyLocal: return .secondary
        case .downloadingFiles: return .accentColor
        case .unknown:          return .secondary
        }
    }
}

/// Switch shown in Settings that flips iCloud sync on/off. Backed by
/// `UserDefaults` (key `BrewTaskNoteUseiCloud`); the manager reads the flag
/// on startup and re-resolves its storage directory every time the value
/// flips.
struct TaskNoteICloudSyncToggle: View {
    @ObservedObject private var manager = TaskReminderManager.shared
    /// Mirrors the manager's opt-out flag (UserDefaults key
    /// `BrewTaskNoteUseiCloud`). The stored value is the *opt-out* state:
    /// `false` (default) = sync enabled, `true` = local-only. The Toggle
    /// binding inverts it so the switch reads as "sync on/off".
    @AppStorage("BrewTaskNoteUseiCloud") private var optedOutStorage: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { !optedOutStorage },
                set: { isOn in
                    let optOut = !isOn
                    optedOutStorage = optOut
                    manager.userOptedOutOfiCloud = optOut
                }
            )) {
                Text("Sync TaskNote via iCloud Drive")
            }
            .help(toggleHelp)

            HStack(spacing: 6) {
                Image(systemName: stateIconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stateTint)
                Text(manager.iCloudSyncState.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let last = manager.lastSyncedAt {
                    Text("· \(Self.relativeLastSynced.localizedString(for: last, relativeTo: Date()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .help(detailTooltip)

            Button {
                manager.forceReconcile()
            } label: {
                Label("Refresh from iCloud", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(manager.iCloudSyncState == .signedOut || manager.iCloudSyncState == .unknown)
        }
    }

    private var toggleHelp: String {
        optedOutStorage
            ? "Tasks are stored locally on this Mac only and will not sync to iCloud. Useful if you want to keep this Mac's tasks separate."
            : "Tasks are stored in your iCloud Drive. Every Mac signed into the same iCloud account sees the same data."
    }

    private var stateIconName: String {
        switch manager.iCloudSyncState {
        case .signedIn:         return "cloud.fill"
        case .signedOut:        return "cloud.slash"
        case .temporarilyLocal: return "icloud.slash"
        case .downloadingFiles: return "arrow.down.circle"
        case .unknown:          return "cloud"
        }
    }

    private var stateTint: Color {
        switch manager.iCloudSyncState {
        case .signedIn:         return .green
        case .signedOut:        return .secondary
        case .temporarilyLocal: return .secondary
        case .downloadingFiles: return .accentColor
        case .unknown:          return .secondary
        }
    }

    private var detailTooltip: String {
        switch manager.iCloudSyncState {
        case .signedIn:
            return "Up to date with iCloud Drive. TaskNote syncs silently in the background."
        case .signedOut:
            return "Sign in to iCloud in System Settings → Apple ID → iCloud to start syncing."
        case .temporarilyLocal:
            return "iCloud sync is turned off. Tasks live in ~/Documents/brew/task-note/ on this Mac only."
        case .downloadingFiles:
            return "Downloading tasks from iCloud Drive on first launch."
        case .unknown:
            return "Initialising iCloud sync."
        }
    }

    private static let relativeLastSynced: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
