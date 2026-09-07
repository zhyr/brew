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
import AppKit

/// Floating task reminder panel shown near the notch.
///
/// Replaces the old clipboard history panel. Unlike clipboard history, this
/// panel only stores user-entered tasks — it never reads or records the
/// system pasteboard. Tasks are quick "remember to do X" entries distinct
/// from full notes (which are delegated to Perch).
struct TaskReminderPanelView: View {
    let onClose: () -> Void
    @ObservedObject private var manager = TaskReminderManager.shared
    @State private var inputText: String = ""
    @State private var hoveredTaskId: UUID?
    @State private var isHeaderHovered: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            inputField
            taskList
        }
        .frame(width: ClipboardPanelMetrics.panelSize.width, height: ClipboardPanelMetrics.panelSize.height)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: ClipboardPanelMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ClipboardPanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 26, x: 0, y: 12)
        .animation(.easeOut(duration: 0.18), value: manager.tasks.count)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.primary)
                .font(.system(size: 15, weight: .semibold))

            Text("Tasks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            if manager.pendingCount > 0 {
                Text("\(manager.pendingCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }

            Spacer()

            iCloudStatusBadge(state: manager.iCloudSyncState)

            if isHeaderHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Close")
                .transition(.opacity)
            } else {
                Color.clear
                    .frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, ClipboardPanelMetrics.contentInset)
        .padding(.top, ClipboardPanelMetrics.contentInset)
        .onHover { isHovered in
            isHeaderHovered = isHovered
        }
        .animation(.easeOut(duration: 0.15), value: isHeaderHovered)
    }

    // MARK: - iCloud status badge

    @ViewBuilder
    private func iCloudStatusBadge(state: TaskReminderSyncState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badgeIconName(for: state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badgeColor(for: state))
            Text(badgeShortText(for: state))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(state.description)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func badgeIconName(for state: TaskReminderSyncState) -> String {
        switch state {
        case .signedIn:         return "cloud.fill"
        case .signedOut:        return "cloud.slash"
        case .temporarilyLocal: return "cloud.slash.fill"
        case .downloadingFiles: return "arrow.down.circle.fill"
        case .unknown:          return "cloud"
        }
    }

    private func badgeColor(for state: TaskReminderSyncState) -> Color {
        switch state {
        case .signedIn:         return .green
        case .signedOut:        return .secondary
        case .temporarilyLocal: return .secondary
        case .downloadingFiles: return .accentColor
        case .unknown:          return .secondary
        }
    }

    private func badgeShortText(for state: TaskReminderSyncState) -> String {
        switch state {
        case .signedIn:         return "iCloud"
        case .signedOut:        return "Local"
        case .temporarilyLocal: return "Local"
        case .downloadingFiles: return "Syncing"
        case .unknown:          return "…"
        }
    }

    // MARK: - Input Field

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13))

            TextField("Add a task… (Enter to save, ⌘V to paste)", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isInputFocused)
                .onSubmit {
                    commitInput()
                }

            Button("Add") {
                commitInput()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        }
        .padding(.horizontal, ClipboardPanelMetrics.contentInset)
    }

    // MARK: - Task List

    @ViewBuilder
    private var taskList: some View {
        // Compute the sorted list once per render. `sortedTasks` is an
        // O(n log n) sort, and the old code invoked it twice (once for the
        // isEmpty check, once in ForEach). Caching it in a local avoids the
        // second pass.
        let sorted = manager.sortedTasks
        if sorted.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(sorted) { task in
                        TaskRow(
                            task: task,
                            isHovered: hoveredTaskId == task.id,
                            onToggle: { manager.toggleCompleted(task) },
                            onDelete: { manager.delete(task) },
                            onAddSubItem: { manager.addSubItem(to: task, title: $0) },
                            onToggleSubItem: { manager.toggleSubItemCompleted(task: task, subItem: $0) },
                            onDeleteSubItem: { manager.deleteSubItem(task: task, subItem: $0) }
                        ) { hoverId in
                            hoveredTaskId = hoverId
                        }
                    }
                }
                .padding(.horizontal, ClipboardPanelMetrics.contentInset)
                .padding(.bottom, ClipboardPanelMetrics.contentInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No tasks yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Type a reminder above and press Enter")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func commitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manager.addTask(text)
        inputText = ""
        isInputFocused = true
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: TaskReminder
    let isHovered: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onAddSubItem: (String) -> Void
    let onToggleSubItem: (TaskSubItem) -> Void
    let onDeleteSubItem: (TaskSubItem) -> Void
    let onHover: (UUID?) -> Void

    /// Shared formatter — creating a RelativeDateTimeFormatter per row per
    /// render is expensive (it allocates locale/calendar data). One static
    /// instance is reused across all rows.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @State private var isAddingSubItem: Bool = false
    @State private var subItemInputText: String = ""
    @State private var hoveredSubItemId: UUID?
    @FocusState private var isSubItemInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            if isAddingSubItem {
                subItemInputField
            }
            if !task.subitems.isEmpty {
                subItemsList
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered in
            onHover(isHovered ? task.id : nil)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isAddingSubItem)
        .animation(.easeOut(duration: 0.15), value: task.subitems.count)
    }

    // MARK: Main row

    private var mainRow: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: onToggle) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.completed ? Color.green : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(task.completed ? .secondary : .primary)
                    .strikethrough(task.completed, color: .secondary)
                    .lineLimit(2)

                Text(timeString)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // Action buttons (hover only)
            if isHovered {
                HStack(spacing: 8) {
                    // Add sub-item button
                    Button(action: {
                        isAddingSubItem.toggle()
                        if isAddingSubItem {
                            isSubItemInputFocused = true
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isAddingSubItem ? Color.accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(isAddingSubItem ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add sub-item")

                    // Delete button
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Sub-item input

    private var subItemInputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 12))

            TextField("Add a sub-item…", text: $subItemInputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($isSubItemInputFocused)
                .onSubmit {
                    commitSubItem()
                }

            Button("Add") {
                commitSubItem()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 26)
        .padding(.vertical, 4)
    }

    private func commitSubItem() {
        let text = subItemInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAddSubItem(text)
        subItemInputText = ""
        isAddingSubItem = false
    }

    // MARK: Sub-items list

    private var subItemsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(task.subitems) { subItem in
                SubItemRow(
                    subItem: subItem,
                    isHovered: hoveredSubItemId == subItem.id,
                    onToggle: { onToggleSubItem(subItem) },
                    onDelete: { onDeleteSubItem(subItem) }
                ) { hoverId in
                    hoveredSubItemId = hoverId
                }
            }
        }
        .padding(.leading, 26)
    }

    private var timeString: String {
        Self.relativeFormatter.localizedString(for: task.createdAt, relativeTo: Date())
    }
}

// MARK: - Sub-item Row

struct SubItemRow: View {
    let subItem: TaskSubItem
    let isHovered: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onHover: (UUID?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox
            Button(action: onToggle) {
                Image(systemName: subItem.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(subItem.completed ? Color.green : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            Text(subItem.title)
                .font(.system(size: 12))
                .foregroundStyle(subItem.completed ? .secondary : .primary)
                .strikethrough(subItem.completed, color: .secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered in
            onHover(isHovered ? subItem.id : nil)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
