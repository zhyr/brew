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

import AtollExtensionKit
import SwiftUI
import Defaults
import AppKit

struct TabModel: Identifiable {
    let id: String
    let label: String
    let icon: String
    let view: NotchViews
    let experienceID: String?
    let accentColor: Color?
    /// When set, clicking this tab launches the external app with the given
    /// bundle identifier via NSWorkspace instead of switching the notch view.
    /// Used to delegate features (e.g. notes) to standalone companion apps
    /// such as Perch (栖痕, https://github.com/zhyr/Perch) by zhyr.
    let externalAppBundleID: String?
    /// Actual app icon image loaded from the app bundle. When set, the tab
    /// renders this image instead of the SF Symbol in `icon`.
    let appIcon: NSImage?

    init(label: String, icon: String, view: NotchViews, experienceID: String? = nil, accentColor: Color? = nil, externalAppBundleID: String? = nil, appIcon: NSImage? = nil) {
        self.id = experienceID.map { "extension-\($0)" } ?? "system-\(view)-\(label)"
        self.label = label
        self.icon = icon
        self.view = view
        self.experienceID = experienceID
        self.accentColor = accentColor
        self.externalAppBundleID = externalAppBundleID
        self.appIcon = appIcon
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var extensionNotchExperienceManager = ExtensionNotchExperienceManager.shared
    @StateObject private var quickShareService = QuickShareService.shared
    @Default(.quickShareProvider) private var quickShareProvider
    @State private var showQuickSharePopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.enableStatsFeature) var enableStatsFeature
    @Default(.enableColorPickerFeature) var enableColorPickerFeature
    @Default(.enableAppLauncherFeature) var enableAppLauncherFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.enableThirdPartyExtensions) private var enableThirdPartyExtensions
    @Default(.enableExtensionNotchExperiences) private var enableExtensionNotchExperiences
    @Default(.enableExtensionNotchTabs) private var enableExtensionNotchTabs
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Namespace var animation
    
    private var tabs: [TabModel] {
        var tabsArray: [TabModel] = []

        // App Launcher is the first tab by default — quick app access is the
        // most frequent action and should be the leftmost position.
        if enableAppLauncherFeature {
            tabsArray.append(TabModel(label: "Apps", icon: "square.grid.2x2.fill", view: .appLauncher))
            // AI Agent activity tab — between Apps and Home. Path conventions
            // for detecting each agent are derived from Al-exporter by zhyr
            // (https://github.com/zhyr/Al-exporter). See
            // AgentActivityProvider.swift for full attribution.
            tabsArray.append(TabModel(label: "Agents", icon: "sparkles.rectangle.stack", view: .agentActivity))
        }

        if homeTabVisible {
            tabsArray.append(TabModel(label: "Home", icon: "house.fill", view: .home))
        }

        if Defaults[.dynamicShelf] {
            tabsArray.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }

        if enableTimerFeature && timerDisplayMode == .tab {
            tabsArray.append(TabModel(label: "Timer", icon: "timer", view: .timer))
        }

        // Stats tab only shown when stats feature is enabled
        if Defaults[.enableStatsFeature] {
            tabsArray.append(TabModel(label: "Stats", icon: "chart.xyaxis.line", view: .stats))
        }

        // Usage tab only shown when LLM usage feature is enabled
        if Defaults[.enableLLMUsageFeature] {
            tabsArray.append(TabModel(label: "Usage", icon: "chart.bar.doc.horizontal", view: .llmUsage))
        }

        // Perch (栖痕) — unified companion app tab for notes/recording.
        // Replaces the old in-notch Notes and Clipboard tabs. Clicking launches
        // the Perch app via NSWorkspace (native macOS sticky notes by zhyr —
        // https://github.com/zhyr/Perch). Only shows when Perch is installed.
        // Uses .home view so the notch never opens the clipboard/notes view.
        if let perchURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.local.perch") {
            tabsArray.append(TabModel(label: "Perch", icon: "note.text", view: .home, externalAppBundleID: "com.local.perch", appIcon: NSWorkspace.shared.icon(forFile: perchURL.path)))
        }
        if Defaults[.enableTerminalFeature] {
            tabsArray.append(TabModel(label: "Terminal", icon: "apple.terminal", view: .terminal))
        }
        if extensionTabsEnabled {
            for payload in extensionTabPayloads {
                guard let tab = payload.descriptor.tab else { continue }
                let accent = payload.descriptor.accentColor.swiftUIColor
                let iconName = tab.iconSymbolName ?? "puzzlepiece.extension"
                tabsArray.append(
                    TabModel(
                        label: tab.title,
                        icon: iconName,
                        view: .extensionExperience,
                        experienceID: payload.descriptor.id,
                        accentColor: accent
                    )
                )
            }
        }
        return tabsArray
    }
    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                let isSelected = isSelected(tab)
                let activeAccent = tab.accentColor ?? .white

                // Render the tab button
                TabButton(label: tab.label, icon: tab.icon, selected: isSelected, appIcon: tab.appIcon) {
                    // External app launcher tabs (e.g. Perch) open the companion
                    // app via NSWorkspace and do not switch the notch view.
                    if let bundleID = tab.externalAppBundleID,
                       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        return
                    }
                    if tab.view == .extensionExperience {
                        coordinator.selectedExtensionExperienceID = tab.experienceID
                    }
                    coordinator.currentView = tab.view
                }
                .frame(height: 26)
                .foregroundStyle(isSelected ? activeAccent : .gray)
                .background {
                    if isSelected {
                        Capsule()
                            .fill((tab.accentColor ?? Color(nsColor: .secondarySystemFill)).opacity(0.25))
                            .shadow(color: (tab.accentColor ?? .clear).opacity(0.4), radius: 8)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                            .hidden()
                    }
                }

                
            }
        }
        .clipShape(Capsule())
        .onAppear {
            ensureValidSelection(with: tabs)
        }
    }

    private var extensionTabsEnabled: Bool {
        enableThirdPartyExtensions && enableExtensionNotchExperiences && enableExtensionNotchTabs
    }

    private var extensionTabPayloads: [ExtensionNotchExperiencePayload] {
        extensionNotchExperienceManager.activeExperiences.filter { $0.descriptor.tab != nil }
    }

    private var homeTabVisible: Bool {
        if enableMinimalisticUI {
            return true
        }
        return showStandardMediaControls || showCalendar || showMirror
    }

    private func isSelected(_ tab: TabModel) -> Bool {
        // External app launcher tabs are never "selected" — they launch the
        // companion app and don't switch the notch view.
        if tab.externalAppBundleID != nil {
            return false
        }
        if tab.view == .extensionExperience {
            return coordinator.currentView == .extensionExperience
                && coordinator.selectedExtensionExperienceID == tab.experienceID
        }
        return coordinator.currentView == tab.view
    }

    private func ensureValidSelection(with tabs: [TabModel]) {
        guard !tabs.isEmpty else { return }
        if tabs.contains(where: { isSelected($0) }) {
            return
        }
        guard let first = tabs.first else { return }
        if first.view == .extensionExperience {
            coordinator.selectedExtensionExperienceID = first.experienceID
        } else {
            coordinator.selectedExtensionExperienceID = nil
        }
        coordinator.currentView = first.view
    }
}

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
