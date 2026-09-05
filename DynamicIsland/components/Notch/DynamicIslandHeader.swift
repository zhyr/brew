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

import Defaults
import os
import SwiftUI

struct DynamicIslandHeader: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @EnvironmentObject var webcamManager: WebcamManager
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @State private var showClipboardPopover = false
    @State private var showColorPickerPopover = false
    @State private var showTimerPopover = false
    /// Cached companion-app URL so click handlers don't run an expensive
    /// `NSWorkspace.urlForApplication` lookup on every tap. Populated lazily
    /// the first time the header appears (or when the user installs Perch
    /// and reopens the notch).
    @State private var perchAppURL: URL?
    /// Real Perch icon, loaded once and reused so the header button shows the
    /// actual app glyph instead of an SF Symbol.
    @State private var perchAppIcon: NSImage?
    /// Visual flash used to acknowledge a Perch click, since the Perch app
    /// is LSUIElement and doesn't get "selected" in the notch.
    @State private var perchFlash = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.showClipboardIcon) var showClipboardIcon
    @Default(.showColorPickerIcon) var showColorPickerIcon
    @Default(.clipboardDisplayMode) var clipboardDisplayMode
    @Default(.showBatteryIndicator) var showBatteryIndicator
    @Default(.showBatteryPercentInside) var showBatteryPercentInside
    @Default(.showMinimalisticBatteryIndicator) var showMinimalisticBatteryIndicator
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    
    /// Point size per symbol, so the row reads as one size.
    ///
    /// Equal point size is equal *cap height*, which is not equal optical size.
    /// Measured at 15pt medium: `gearshape` covers 289pt² of ink against
    /// `web.camera`'s 208 — 39% more — and `list.clipboard` stands 19pt tall
    /// against `timer`'s 16. These sizes were solved so every glyph lands on
    /// 16pt of ink height, which is what actually makes a mixed row look even.
    private static let headerGlyphSizes: [String: CGFloat] = [
        "web.camera": 14.5,
        "list.clipboard": 13,
        "eyedropper": 14.3,
        "timer": 14.4,
        "gearshape": 14.2
    ]

    /// One glyph in the header row, on a common centre.
    ///
    /// The 20pt box clears the largest frame any of these symbols asks for
    /// (19pt, `list.clipboard`), so none of them is clipped — a smaller box
    /// silently cuts the tall ones.
    private func headerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundColor(.white)
            .font(.system(size: Self.headerGlyphSizes[name] ?? 14.4, weight: .medium))
            .frame(width: 20, height: 20)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if !enableMinimalisticUI {
                    let shouldShowTabs = coordinator.alwaysShowTabs || vm.notchState == .open || !shelfState.items.isEmpty
                    if shouldShowTabs {
                        TabSelectionView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
            .padding(8)

            if vm.notchState == .open {
                let spacerWidth = min(vm.closedNotchSize.width, 300)
                Rectangle()
                    .fill(enableMinimalisticUI ? .clear : (NSScreen.screens
                        .first(where: { $0.localizedName == coordinator.selectedScreen })?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear))
                    .frame(width: spacerWidth)
                    .mask {
                        NotchShape()
                    }
            }

            // 30pt targets sitting 4pt apart read as one run of buttons rather
            // than as separate ones; 8 is the gap Apple leaves between controls
            // of this size.
            HStack(spacing: 8) {
                if vm.notchState == .open && !enableMinimalisticUI {
                    if Defaults[.showMirror] {
                        Button(action: {
                            vm.toggleCameraPreview()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("web.camera")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    if Defaults[.enableClipboardManager]
                        && showClipboardIcon
                        && clipboardDisplayMode != .separateTab {
                        Button(action: {
                            // Switch behavior based on display mode.
                            // `.panel` now opens the task reminder panel
                            // (repurposed from clipboard history to avoid
                            // overlap with Perch notes).
                            switch clipboardDisplayMode {
                            case .panel:
                                ClipboardPanelManager.shared.toggleClipboardPanel()
                            case .popover:
                                // Popover mode shows the task reminder panel
                                // as a dropdown anchored to this button.
                                showClipboardPopover.toggle()
                            case .separateTab:
                                coordinator.currentView = .notes
                            case .notchTab:
                                // Cancel the auto-close armed by toggleNotchOpen so it can't
                                // close the notch shortly after we switch into the clipboard tab.
                                AppDelegate.shared?.cancelPendingNotchAutoClose()
                                // Toggle: a second tap on the clipboard button leaves the tab.
                                coordinator.currentView = (coordinator.currentView == .clipboard) ? .home : .clipboard
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("checklist")
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    TaskNoteSyncBadge()
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showClipboardPopover, arrowEdge: .bottom) {
                            ClipboardPopover {
                                showClipboardPopover = false
                            }
                        }
                        .onChange(of: showClipboardPopover) { isActive in
                            vm.isClipboardPopoverActive = isActive
                            
                            // If popover was closed, trigger a hover recheck
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                        .onAppear {
                            if Defaults[.enableClipboardManager] && !clipboardManager.isMonitoring {
                                clipboardManager.startMonitoring()
                            }
                        }
                    }

                    // Perch (栖痕 / zhyr/Perch) launcher button. Sits to the
                    // right of the TaskNote button so the two companion-app
                    // controls read as one row. Hidden when Perch isn't
                    // installed (the cached URL stays nil).
                    if let perchURL = perchAppURL {
                        Button(action: launchPerch) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if let icon = perchAppIcon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                    } else {
                                        headerGlyph("note.text")
                                    }
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Perch（栖痕）")
                        .onAppear {
                            // Icon may have been nil if the URL was just
                            // resolved by the cache step below — fill it now.
                            if perchAppIcon == nil {
                                perchAppIcon = NSWorkspace.shared.icon(forFile: perchURL.path)
                            }
                        }
                    }

                    // ColorPicker button
                    if Defaults[.enableColorPickerFeature] && showColorPickerIcon{
                        Button(action: {
                            switch Defaults[.colorPickerDisplayMode] {
                            case .panel:
                                ColorPickerPanelManager.shared.toggleColorPickerPanel()
                            case .popover:
                                showColorPickerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("eyedropper")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showColorPickerPopover, arrowEdge: .bottom) {
                            ColorPickerPopover()
                        }
                        .onChange(of: showColorPickerPopover) { isActive in
                            vm.isColorPickerPopoverActive = isActive
                            
                            // If popover was closed, trigger a hover recheck
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }
                    
                    if Defaults[.enableTimerFeature] && timerDisplayMode == .popover {
                        Button(action: {
                            withAnimation(.smooth) {
                                showTimerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("timer")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showTimerPopover, arrowEdge: .bottom) {
                            TimerPopover()
                        }
                        .onChange(of: showTimerPopover) { isActive in
                            vm.isTimerPopoverActive = isActive
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }
                    
                    if Defaults[.settingsIconInNotch] {
                        Button(action: {
                            SettingsWindowController.shared.showWindow()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    headerGlyph("gearshape")
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // Screen Recording Indicator
                    if Defaults[.enableScreenRecordingDetection] && Defaults[.showRecordingIndicator] && !shouldSuppressStatusIndicators {
                        RecordingIndicator()
                            .frame(width: 30, height: 30) // Same size as other header elements
                    }

                    if Defaults[.enableDoNotDisturbDetection]
                        && Defaults[.showDoNotDisturbIndicator]
                        && doNotDisturbManager.isDoNotDisturbActive
                        && !shouldSuppressStatusIndicators {
                        FocusIndicator()
                            .frame(width: 30, height: 30)
                            .transition(.opacity)
                    }
                }

                if vm.notchState == .open && showBatteryIndicator {
                    if enableMinimalisticUI {
                        // In minimalistic notch mode, show the battery pill only when
                        // showMinimalisticBatteryIndicator is enabled (and not DI mode).
                        if !shouldUseDynamicIslandMode(for: vm.screen) && showMinimalisticBatteryIndicator {
                            MinimalisticBatteryView(
                                levelBattery: batteryModel.levelBattery,
                                isPluggedIn: batteryModel.isPluggedIn,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                bodyWidth: 28,
                                bodyHeight: 14,
                                isForNotification: false,
                                showPercentInside: showBatteryPercentInside
                            )
                            .padding(.trailing, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    } else {
                        DynamicIslandBatteryView(
                            batteryWidth: 30,
                            isCharging: batteryModel.isCharging,
                            isInLowPowerMode: batteryModel.isInLowPowerMode,
                            isPluggedIn: batteryModel.isPluggedIn,
                            levelBattery: batteryModel.levelBattery,
                            maxCapacity: batteryModel.maxCapacity,
                            timeToFullCharge: batteryModel.timeToFullCharge,
                            isForNotification: false
                        )
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
        .onAppear {
            // Populate the cached Perch URL the first time the header
            // appears so the launcher button can render. The button is
            // gated on `perchAppURL != nil`, so without this call Perch
            // would never appear in the row.
            //
            // `cachePerchAppIfNeeded` self-guards against repeat lookups
            // (the SwiftUI `.onAppear` may fire on every parent re-render),
            // and the lookup is cheap — `NSWorkspace` keeps its index hot.
            cachePerchAppIfNeeded()
        }
        .onChange(of: coordinator.shouldToggleClipboardPopover) { _ in
            // Only toggle if clipboard is enabled
            if Defaults[.enableClipboardManager] {
                switch clipboardDisplayMode {
                case .panel:
                    ClipboardPanelManager.shared.toggleClipboardPanel()
                case .popover:
                    showClipboardPopover.toggle()
                case .separateTab:
                    if coordinator.currentView == .notes {
                        coordinator.currentView = .home
                    } else {
                        coordinator.currentView = .notes
                    }
                case .notchTab:
                    // Same as the header button: don't let the armed auto-close fire after
                    // we switch into the clipboard tab.
                    AppDelegate.shared?.cancelPendingNotchAutoClose()
                    if coordinator.currentView == .clipboard {
                        coordinator.currentView = .home
                    } else {
                        coordinator.currentView = .clipboard
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleClipboardPopover"))) { _ in
            // Handle keyboard shortcut for popover mode
            if Defaults[.enableClipboardManager] && clipboardDisplayMode == .popover {
                showClipboardPopover.toggle()
            }
        }
        .onChange(of: enableTimerFeature) { _, newValue in
            if !newValue {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
        .onChange(of: timerDisplayMode) { _, mode in
            if mode == .tab {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
    }
}

private extension DynamicIslandHeader {
    var shouldSuppressStatusIndicators: Bool {
        Defaults[.settingsIconInNotch]
            && Defaults[.enableClipboardManager]
            && Defaults[.showClipboardIcon]
            && Defaults[.showColorPickerIcon]
            && Defaults[.enableTimerFeature]
    }

    // MARK: - Perch launcher

    /// Bundle identifier for the Perch companion app
    /// (https://github.com/zhyr/Perch). Kept here so the launch path is
    /// the single place that knows about Perch.
    private static let perchBundleID = "com.local.perch"

    /// Launch Perch and bring its floating panel to the foreground.
    ///
    /// Perch is an `LSUIElement` app, so the usual `NSWorkspace
    /// .OpenConfiguration.activates = true` is silently ignored — both on
    /// cold start (LaunchServices starts the process but never raises its
    /// window) and on re-launch (the running instance is asked to open
    /// again, which is a no-op for an already-running single-instance app).
    ///
    /// The reliable path is `NSRunningApplication.activate(...)` against the
    /// already-running instance, falling back to AppleScript after a cold
    /// start once the app has had a moment to register with LaunchServices.
    private func launchPerch() {
        // 1. Fast path: Perch is already running. NSRunningApplication is
        //    the only call that consistently raises an LSUIElement window
        //    back to the front.
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.perchBundleID
        ).first {
            running.activate(options: [.activateAllWindows])
            flashPerchButton()
            return
        }

        // 2. Cold start. NSWorkspace.launch will start the binary, but the
        //    activationPolicy(.accessory) means the panel isn't shown until
        //    the app itself decides to show it (Perch shows its popover
        //    ~0.35s after launch). After that grace period we ask AppleScript
        //    to activate it as a belt-and-braces in case the panel didn't
        //    surface — NSAppleEventsUsageDescription is declared in Info.plist.
        let url = perchAppURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.perchBundleID)
        guard let url else {
            // Perch isn't installed; the button shouldn't have been visible,
            // but guard anyway so a race during install doesn't crash.
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // `DynamicIslandHeader` is a SwiftUI value type (struct), so
            // `[weak self]` is invalid. Capture by value — `self` here is a
            // cheap value copy and `activatePerchViaAppleScript()` only
            // touches module-level state, so this is safe and self-contained.
            self.activatePerchViaAppleScript()
        }

        flashPerchButton()
    }

    private func activatePerchViaAppleScript() {
        let script = NSAppleScript(source: """
        tell application "Perch"
            activate
        end tell
        """)
        // `executeAndReturnError(_:)` writes an `NSDictionary?` on failure;
        // `NSErr` is not a real type.
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSLocalizedDescriptionKey] as? String ?? errorInfo.description
            os_log(
                .error,
                log: perchLaunchLog,
                "AppleScript activate Perch failed: %{public}@",
                message
            )
        }
    }

    private func flashPerchButton() {
        withAnimation(.easeOut(duration: 0.15)) {
            perchFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.2)) {
                perchFlash = false
            }
        }
    }

    private func cachePerchAppIfNeeded() {
        guard perchAppURL == nil else { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.perchBundleID) {
            perchAppURL = url
            perchAppIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

private let perchLaunchLog = OSLog(
    subsystem: "com.brew.dynamicisland",
    category: "PerchLauncher"
)

#Preview {
    DynamicIslandHeader()
        .environmentObject(DynamicIslandViewModel())
        .environmentObject(WebcamManager.shared)
}
