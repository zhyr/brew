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
import SwiftUI

private func applyClipboardCornerMask(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = NSColor.clear.cgColor
    if #available(macOS 13.0, *) {
        view.layer?.cornerCurve = .continuous
    }
}

class ClipboardPanel: NSPanel {
    
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        setupWindow()
        setupContentView()
    }
    
    // Override to allow the panel to become key window (required for TextField focus)
    override var canBecomeKey: Bool {
        return true
    }
    
    // Override to allow the panel to become main window (required for text input)
    override var canBecomeMain: Bool {
        return true
    }
    
    private func setupWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true  // Enable dragging
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true  // Mark as floating panel for proper behavior
        
        // Allow dragging from any part of the window
        styleMask.insert(.fullSizeContentView)
        
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary  // Float above full-screen apps
        ]

        ScreenCaptureVisibilityManager.shared.register(self, scope: .panelsOnly)
        
        // Accept mouse moved events for proper hover behavior
        acceptsMouseMovedEvents = true
    }
    
    private func setupContentView() {
        // The floating panel now hosts the task reminder view instead of
        // clipboard history. Clipboard history is still available via the
        // notch's clipboard tab; this panel is intentionally repurposed for
        // quick task reminders to avoid overlap with Perch (notes).
        let contentView = TaskReminderPanelView {
            self.close()
        }

        let hostingView = NSHostingView(rootView: contentView)
        applyClipboardCornerMask(hostingView, radius: ClipboardPanelMetrics.cornerRadius)
        self.contentView = hostingView

        // Set initial size
        let preferredSize = ClipboardPanelMetrics.panelSize
        hostingView.setFrameSize(preferredSize)
        setContentSize(preferredSize)
    }
    
    func positionNearNotch() {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let panelFrame = frame
        
        // Check if we have a saved position
        if let savedPosition = getSavedPosition() {
            let savedFrame = NSRect(origin: savedPosition, size: panelFrame.size)
            if screenFrame.contains(savedFrame) {
                setFrameOrigin(savedPosition)
                return
            }
            // Merely intersecting is not enough: a position saved when the
            // panel was narrower can now hang off the edge. Nudge it back
            // inside rather than throwing the user's placement away.
            if screenFrame.intersects(savedFrame) {
                setFrameOrigin(
                    ClipboardPanel.clampedOrigin(savedPosition, size: panelFrame.size, within: screenFrame)
                )
                return
            }
        }
        
        // Default to center of screen (not top center)
        let xPosition = (screenFrame.width - panelFrame.width) / 2 + screenFrame.minX
        let yPosition = (screenFrame.height - panelFrame.height) / 2 + screenFrame.minY
        
        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }
    
    /// Keeps a frame of `size` fully inside `bounds`, pinning to the origin
    /// edges if the panel is somehow larger than the visible frame.
    static func clampedOrigin(_ origin: NSPoint, size: NSSize, within bounds: NSRect) -> NSPoint {
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, bounds.minX), maxX),
            y: min(max(origin.y, bounds.minY), maxY)
        )
    }

    private func getSavedPosition() -> NSPoint? {
        let defaults = UserDefaults.standard
        let x = defaults.double(forKey: "clipboardPanelPositionX")
        let y = defaults.double(forKey: "clipboardPanelPositionY")
        
        // Check if we have valid saved coordinates (not default 0.0)
        if x != 0.0 || y != 0.0 {
            return NSPoint(x: x, y: y)
        }
        return nil
    }
    
    private func saveCurrentPosition() {
        let currentOrigin = frame.origin
        let defaults = UserDefaults.standard
        defaults.set(currentOrigin.x, forKey: "clipboardPanelPositionX")
        defaults.set(currentOrigin.y, forKey: "clipboardPanelPositionY")
    }
    
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        // Save position whenever it changes (user dragging)
        saveCurrentPosition()
    }
    
    func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let panelFrame = frame
        
        // Position near mouse but ensure it stays on screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        var xPosition = mouseLocation.x - panelFrame.width / 2
        var yPosition = mouseLocation.y - panelFrame.height - 20
        
        // Keep within screen bounds
        xPosition = max(screenFrame.minX + 10, min(xPosition, screenFrame.maxX - panelFrame.width - 10))
        yPosition = max(screenFrame.minY + 10, min(yPosition, screenFrame.maxY - panelFrame.height - 10))
        
        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }
    
}

enum ClipboardPanelMetrics {
    static let panelSize = CGSize(width: 380, height: 480)
    static let cornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 12
    static let contentInset: CGFloat = 12
}
