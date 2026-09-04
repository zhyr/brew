/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import Sparkle

// Auto-update disabled for local self-build distribution.
// These views are kept as no-ops for source compatibility with
// call sites in DynamicIslandApp.swift and SettingsView.swift.

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // No-op: auto-update disabled.
    }
}

struct CheckForUpdatesView: View {
    init(updater: SPUUpdater) {
        // No-op: auto-update disabled.
    }

    var body: some View {
        EmptyView()
    }
}

struct UpdaterSettingsView: View {
    init(updater: SPUUpdater) {
        // No-op: auto-update disabled.
    }

    var body: some View {
        EmptyView()
    }
}
