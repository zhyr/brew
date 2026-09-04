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
import AppKit

/// "AI Agent" tab — shows what each AI coding agent on this machine is
/// currently doing. Sits between "Apps" and "Home" in the tab order.
///
/// The detection logic is in `AgentActivityProvider.swift` (Trae / Cursor /
/// Codex / WorkBuddy). Path conventions for each tool are derived from
/// the open-source Al-exporter project by zhyr — see the attribution in
/// `AgentActivityProvider.swift` for details.
struct NotchAgentActivityView: View {
    @ObservedObject private var monitor = AgentActivityMonitor.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Per-provider summary row at the top: one compact status
                // chip per installed agent. Uninstalled agents are hidden.
                HStack(spacing: 6) {
                    ForEach(monitor.providers, id: \.productID) { provider in
                        if provider.isInstalled {
                            providerChip(provider)
                        }
                    }
                    Spacer(minLength: 0)
                    if monitor.isRefreshing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }

                // Detailed task list below.
                if monitor.tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(monitor.tasks) { task in
                        taskCard(task)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        }
        .onAppear { monitor.startPolling() }
        .onDisappear { monitor.stopPolling() }
    }

    // MARK: - Subviews

    /// Compact chip: icon + name + colored status dot. 16-pt tall.
    @ViewBuilder
    private func providerChip(_ provider: AgentActivityProvider) -> some View {
        let isRunning = monitor.runningProviders.contains(provider.productID)
        HStack(spacing: 4) {
            Image(systemName: provider.iconSystemName)
                .foregroundStyle(Color(nsColor: provider.accentColor))
                .font(.caption)
            Text(provider.displayName)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.85))
            Circle()
                .fill(isRunning ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
        )
    }

    /// A single task row — full-width card.
    @ViewBuilder
    private func taskCard(_ task: AgentTask) -> some View {
        let provider = monitor.providers.first { $0.productID == task.productID }
        let accent = provider.map { Color(nsColor: $0.accentColor) } ?? .blue
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let provider {
                    Image(systemName: provider.iconSystemName)
                        .foregroundStyle(accent)
                        .font(.callout)
                }
                Text(provider?.displayName ?? task.productID)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                statusBadge(task.status, accent: accent)
            }

            Text(task.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let hint = task.progressHint {
                HStack(spacing: 4) {
                    if task.status == .running {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                    }
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            }

            if let updated = task.lastUpdatedAt {
                Text(formatRelative(updated))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accent.opacity(0.25), lineWidth: 1)
                )
        )
    }

    /// Small colored status pill.
    @ViewBuilder
    private func statusBadge(_ status: AgentTask.Status, accent: Color) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running: return ("running", .green)
            case .idle: return ("idle", .gray)
            case .awaitingUser: return ("waiting", .orange)
            case .completed: return ("done", .blue)
            case .unknown: return ("—", .gray)
            }
        }()
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No agent running")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Text("Start a session in Trae / Cursor / Codex / WorkBuddy to see progress here.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Helpers

    /// Format a date as "just now" / "12s ago" / "3m ago" / "1h ago".
    private func formatRelative(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 5 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }
}
