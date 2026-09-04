/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details
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

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    /// Optional app icon image. When provided, renders this image instead of
    /// the SF Symbol specified by `icon`. Used for companion-app launcher tabs
    /// (e.g. Recordly, iShot Pro, Perch) so the tab shows the actual app icon.
    let appIcon: NSImage?

    init(label: String, icon: String, selected: Bool, appIcon: NSImage? = nil, onClick: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.selected = selected
        self.appIcon = appIcon
        self.onClick = onClick
    }

    var body: some View {
        Button(action: onClick) {
            if let appIcon = appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .contentShape(Capsule())
            } else {
                Image(systemName: icon)
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
