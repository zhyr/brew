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

import SwiftUI

/// Popover attached to the notch header TaskNote button.
///
/// Unlike the floating panel (`.panel` mode), the popover is anchored to the
/// button and dismisses on outside click. It hosts the same task reminder
/// content so both panel and popover modes expose the TaskNote feature.
struct ClipboardPopover: View {
    var onClose: () -> Void = {}

    var body: some View {
        TaskReminderPanelView(onClose: onClose)
    }
}

#Preview {
    ClipboardPopover()
}
