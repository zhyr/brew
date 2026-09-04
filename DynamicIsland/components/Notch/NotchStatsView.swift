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
import Defaults
import AppKit

// Graph data protocol for unified interface
protocol GraphData {
    var title: String { get }
    var color: Color { get }
    var icon: String { get }
    var type: GraphType { get }
    var rankingType: ProcessRankingType? { get }
}

enum GraphType {
    case single
    case dual
}

// Single value graph data
struct SingleGraphData: GraphData {
    let title: String
    let value: String
    let data: [Double]
    let color: Color
    let icon: String
    let type: GraphType = .single
    let rankingType: ProcessRankingType?
}

// Dual value graph data (for network/disk)
struct DualGraphData: GraphData {
    let title: String
    let positiveValue: String
    let negativeValue: String
    let positiveData: [Double]
    let negativeData: [Double]
    let positiveColor: Color
    let negativeColor: Color
    let color: Color // Primary color for the component
    let icon: String
    let type: GraphType = .dual
    let rankingType: ProcessRankingType?
}

struct NotchStatsView: View {
    @ObservedObject var statsManager = StatsManager.shared
    @ObservedObject private var diskCleaner = DiskCleaner.shared
    @Default(.enableStatsFeature) var enableStatsFeature
    @Default(.showCpuGraph) var showCpuGraph
    @Default(.showMemoryGraph) var showMemoryGraph
    @Default(.showGpuGraph) var showGpuGraph
    @Default(.showNetworkGraph) var showNetworkGraph
    @Default(.showDiskGraph) var showDiskGraph
    @State private var showingCPUPopover = false
    @State private var showingMemoryPopover = false
    @State private var showingGPUPopover = false
    @State private var showingNetworkPopover = false
    @State private var showingDiskPopover = false
    @State private var isHoveringCPUPopover = false
    @State private var isHoveringMemoryPopover = false
    @State private var isHoveringGPUPopover = false
    @State private var isHoveringNetworkPopover = false
    @State private var isHoveringDiskPopover = false
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared

    var availableGraphs: [GraphData] {
        var graphs: [GraphData] = []

        if showCpuGraph {
            graphs.append(SingleGraphData(
                title: String(localized: "CPU"),
                value: statsManager.cpuUsageString,
                data: statsManager.cpuHistory,
                color: .blue,
                icon: "cpu",
                rankingType: .cpu
            ))
        }

        if showMemoryGraph {
            graphs.append(SingleGraphData(
                title: String(localized: "Memory"),
                value: statsManager.memoryUsageString,
                data: statsManager.memoryHistory,
                color: .green,
                icon: "memorychip",
                rankingType: .memory
            ))
        }

        if showGpuGraph {
            graphs.append(SingleGraphData(
                title: String(localized: "GPU"),
                value: statsManager.gpuUsageString,
                data: statsManager.gpuHistory,
                color: .purple,
                icon: "display",
                rankingType: .gpu
            ))
        }

        if showNetworkGraph {
            graphs.append(DualGraphData(
                title: String(localized: "Network"),
                positiveValue: "↓" + statsManager.networkDownloadString,
                negativeValue: "↑" + statsManager.networkUploadString,
                positiveData: statsManager.networkDownloadHistory,
                negativeData: statsManager.networkUploadHistory,
                positiveColor: .orange,
                negativeColor: .red,
                color: .orange,
                icon: "network",
                rankingType: .network
            ))
        }

        if showDiskGraph {
            graphs.append(DualGraphData(
                title: String(localized: "Disk"),
                positiveValue: String(localized: "R ") + statsManager.diskReadString,
                negativeValue: String(localized: "W ") + statsManager.diskWriteString,
                positiveData: statsManager.diskReadHistory,
                negativeData: statsManager.diskWriteHistory,
                positiveColor: .cyan,
                negativeColor: .yellow,
                color: .cyan,
                icon: "internaldrive",
                rankingType: .disk
            ))
        }

        return graphs
    }

    // Smart grid layout system for different graph counts
    @ViewBuilder
    var statsGridLayout: some View {
        let graphCount = availableGraphs.count

        if graphCount <= 3 {
            // 1-3 graphs: Single row with equal spacing
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: graphCount),
                spacing: 12
            ) {
                ForEach(0..<graphCount, id: \.self) { index in
                    graphViewForIndex(index)
                }
            }
        } else if graphCount == 4 {
            // 4 graphs: two rows (2x2) without a collapsible expansion
            VStack(spacing: statsGridSpacingHeight) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 12
                ) {
                    ForEach(0..<2, id: \.self) { index in
                        graphViewForIndex(index)
                    }
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 12
                ) {
                    ForEach(2..<graphCount, id: \.self) { index in
                        graphViewForIndex(index)
                    }
                }
            }
        } else {
            // 5 graphs: First row 3 graphs, second row 2 graphs (half-width each)
            VStack(spacing: statsGridSpacingHeight) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(0..<3, id: \.self) { index in
                        graphViewForIndex(index)
                    }
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 8
                ) {
                    ForEach(3..<graphCount, id: \.self) { index in
                        graphViewForIndex(index)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func graphViewForIndex(_ index: Int) -> some View {
        let graphData = availableGraphs[index]

        if let rankingType = rankingTypeForGraph(graphData) {
            Button(action: {
                handleGraphClick(for: graphData)
            }) {
                UnifiedStatsCard(graphData: graphData)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: bindingForGraph(graphData)) {
                RankedProcessPopover(
                    rankingType: rankingType,
                    onHoverChange: { hovering in
                        switch rankingType {
                        case .cpu:
                            isHoveringCPUPopover = hovering
                        case .memory:
                            isHoveringMemoryPopover = hovering
                        case .gpu:
                            isHoveringGPUPopover = hovering
                        case .network:
                            isHoveringNetworkPopover = hovering
                        case .disk:
                            isHoveringDiskPopover = hovering
                        }
                    }
                )
                .onDisappear {
                    switch rankingType {
                    case .cpu:
                        isHoveringCPUPopover = false
                    case .memory:
                        isHoveringMemoryPopover = false
                    case .gpu:
                        isHoveringGPUPopover = false
                    case .network:
                        isHoveringNetworkPopover = false
                    case .disk:
                        isHoveringDiskPopover = false
                    }
                    DispatchQueue.main.async {
                        updateStatsPopoverState()
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4)),
                removal: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4))
            ))
        } else {
            UnifiedStatsCard(graphData: graphData)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4)),
                    removal: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4))
                ))
        }
    }

    private func handleGraphClick(for graphData: GraphData) {
        switch graphData.rankingType {
        case .cpu:
            showingCPUPopover = true
        case .memory:
            showingMemoryPopover = true
        case .gpu:
            showingGPUPopover = true
        case .network:
            showingNetworkPopover = true
        case .disk:
            showingDiskPopover = true
        case nil:
            break
        }
    }

    private func bindingForGraph(_ graphData: GraphData) -> Binding<Bool> {
        switch graphData.rankingType {
        case .cpu:
            return $showingCPUPopover
        case .memory:
            return $showingMemoryPopover
        case .gpu:
            return $showingGPUPopover
        case .network:
            return $showingNetworkPopover
        case .disk:
            return $showingDiskPopover
        case nil:
            return .constant(false)
        }
    }

    private func rankingTypeForGraph(_ graphData: GraphData) -> ProcessRankingType? {
        graphData.rankingType
    }
    
    // Helper function to create graph views using unified component
    @ViewBuilder
    func graphView(for graphData: GraphData) -> some View {
        UnifiedStatsCard(graphData: graphData)
    }

    var body: some View {
        // Wrap the whole tab body in a vertical ScrollView so when content
        // (the stats grid + the 3 new disk/cleanup cards) exceeds the notch
        // window height, the user can scroll the inner region without the
        // window itself having to grow. The disabled/empty states still
        // center vertically inside the ScrollView.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if !enableStatsFeature {
                // Disabled state
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    
                    Text("Stats Disabled")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Enable stats monitoring in Settings to view system performance data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if availableGraphs.isEmpty {
                // No graphs enabled state
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    
                    Text("No Graphs Enabled")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Enable graph visibility in Settings → Stats to view performance data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(spacing: 8) {
                    statsGridLayout

                    // ─────────────────────────────────────────────────────────
                    // Disk & Cleanup cards (3 cards, 1 row).
                    // The cleanup logic itself is delegated to the bundled
                    // `disk_maintenance.sh` v4.0.0 from
                    // https://github.com/zhyr/LLM-based-Software-Devlopment-Kit-Suite
                    // by zhyr. See DiskCleaner.swift for full attribution.
                    // ─────────────────────────────────────────────────────────
                    HStack(spacing: 8) {
                        DiskUsageStatsCard(diskCleaner: diskCleaner)
                        SystemCleanerCard(diskCleaner: diskCleaner)
                        DevCleanerCard(diskCleaner: diskCleaner)
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.4), value: availableGraphs.count)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4)),
                    removal: .scale.combined(with: .opacity).animation(.easeInOut(duration: 0.4))
                ))
            }
        }
        }  // closes VStack(spacing: 0) + ScrollView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Note: Smart monitoring will handle starting/stopping based on notch state and current view
            diskCleaner.startPolling()
        }
        .onDisappear {
            // Keep monitoring running when tab is not visible
            updateStatsPopoverState()
            diskCleaner.stopPolling()
        }
        .animation(.easeInOut(duration: 0.4), value: enableStatsFeature)
        .animation(.easeInOut(duration: 0.4), value: availableGraphs.count)
        .onChange(of: showingCPUPopover) { _, newValue in
            updateStatsPopoverState()
        }
        .onChange(of: showingMemoryPopover) { _, newValue in
            updateStatsPopoverState()
        }
        .onChange(of: showingGPUPopover) { _, newValue in
            updateStatsPopoverState()
        }
        .onChange(of: showingNetworkPopover) { _, newValue in
            updateStatsPopoverState()
        }
        .onChange(of: showingDiskPopover) { _, newValue in
            updateStatsPopoverState()
        }
        .onChange(of: isHoveringCPUPopover) { _, _ in
            updateStatsPopoverState()
        }
        .onChange(of: isHoveringMemoryPopover) { _, _ in
            updateStatsPopoverState()
        }
        .onChange(of: isHoveringGPUPopover) { _, _ in
            updateStatsPopoverState()
        }
        .onChange(of: isHoveringNetworkPopover) { _, _ in
            updateStatsPopoverState()
        }
        .onChange(of: isHoveringDiskPopover) { _, _ in
            updateStatsPopoverState()
        }
    }
    private func updateStatsPopoverState() {
        let anyPopoverOpen = showingCPUPopover || showingMemoryPopover || showingGPUPopover || showingNetworkPopover || showingDiskPopover
        let newState = anyPopoverOpen
        if vm.isStatsPopoverActive != newState {
            vm.isStatsPopoverActive = newState
            #if DEBUG
            print("📊 Stats popover state updated: \(newState)")
            print("   CPU open=\(showingCPUPopover)")
            print("   Memory open=\(showingMemoryPopover)")
            print("   GPU open=\(showingGPUPopover)")
            print("   Network open=\(showingNetworkPopover)")
            print("   Disk open=\(showingDiskPopover)")
            #endif
        }
    }
}

// Unified Stats Card Component - handles both single and dual data types, matches boring.notch sizing
struct UnifiedStatsCard: View {
    let graphData: GraphData
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 3) { // Match boring.notch spacing
            // Header - consistent across all card types
            HStack(spacing: 4) {
                Image(systemName: graphData.icon)
                    .foregroundStyle(graphData.color)
                    .font(.caption) // Match boring.notch font size
                
                Text(graphData.title)
                    .font(.caption) // Match boring.notch font size
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.8))
                
                Spacer()
            }
            
            // Values section - same height for every card so the grid boxes match
            Group {
                if let singleData = graphData as? SingleGraphData {
                    Text(singleData.value)
                        .font(.caption) // Match boring.notch font size
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                } else if let dualData = graphData as? DualGraphData {
                    HStack(spacing: 6) {
                        Text(dualData.positiveValue)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(dualData.positiveColor)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.45))
                        
                        Text(dualData.negativeValue)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(dualData.negativeColor)
                    }
                }
            }
            .frame(height: 18) // Fixed height for the values section
            
            // Graph section - adapts based on graph type
            Group {
                if let singleData = graphData as? SingleGraphData {
                    MiniGraph(data: singleData.data, color: singleData.color)
                } else if let dualData = graphData as? DualGraphData {
                    DualQuadrantGraph(
                        positiveData: dualData.positiveData,
                        negativeData: dualData.negativeData,
                        positiveColor: dualData.positiveColor,
                        negativeColor: dualData.negativeColor
                    )
                }
            }
            .frame(height: 36) // Match boring.notch exactly - reduced from 50
            
            // Click hint - shown for graphs that open popovers
            if graphData.rankingType != nil {
                Text("Click for details")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .opacity(isHovered ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
            }
        }
        .padding(8) // Match boring.notch padding - reduced from 10
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct MiniGraph: View {
    let data: [Double]
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            let maxValue = data.max() ?? 1.0
            let normalizedData = maxValue > 0 ? data.map { $0 / maxValue } : data
            
            Path { path in
                guard !normalizedData.isEmpty else { return }
                
                let stepX = geometry.size.width / CGFloat(normalizedData.count - 1)
                
                for (index, value) in normalizedData.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = geometry.size.height * (1 - CGFloat(value))
                    
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, lineWidth: 2)
            
            // Gradient fill
            Path { path in
                guard !normalizedData.isEmpty else { return }
                
                let stepX = geometry.size.width / CGFloat(normalizedData.count - 1)
                
                path.move(to: CGPoint(x: 0, y: geometry.size.height))
                
                for (index, value) in normalizedData.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = geometry.size.height * (1 - CGFloat(value))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [color.opacity(0.3), color.opacity(0.1)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}



struct DualQuadrantGraph: View {
    let positiveData: [Double]
    let negativeData: [Double]
    let positiveColor: Color
    let negativeColor: Color
    
    var body: some View {
        GeometryReader { geometry in
            let maxPositive = positiveData.max() ?? 1.0
            let maxNegative = negativeData.max() ?? 1.0
            let maxValue = max(maxPositive, maxNegative)
            
            let normalizedPositive = maxValue > 0 ? positiveData.map { $0 / maxValue } : positiveData
            let normalizedNegative = maxValue > 0 ? negativeData.map { $0 / maxValue } : negativeData
            
            let centerY = geometry.size.height / 2
            
            ZStack {
                // Center dividing line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: centerY))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: centerY))
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                
                // Positive quadrant (upper half)
                Path { path in
                    guard !normalizedPositive.isEmpty else { return }
                    
                    let stepX = geometry.size.width / CGFloat(normalizedPositive.count - 1)
                    
                    for (index, value) in normalizedPositive.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = centerY - (centerY * CGFloat(value)) // Above center
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(positiveColor, lineWidth: 2)
                
                // Positive fill
                Path { path in
                    guard !normalizedPositive.isEmpty else { return }
                    
                    let stepX = geometry.size.width / CGFloat(normalizedPositive.count - 1)
                    
                    path.move(to: CGPoint(x: 0, y: centerY))
                    
                    for (index, value) in normalizedPositive.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = centerY - (centerY * CGFloat(value))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    
                    path.addLine(to: CGPoint(x: geometry.size.width, y: centerY))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [positiveColor.opacity(0.3), positiveColor.opacity(0.1)]),
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                
                // Negative quadrant (lower half)
                Path { path in
                    guard !normalizedNegative.isEmpty else { return }
                    
                    let stepX = geometry.size.width / CGFloat(normalizedNegative.count - 1)
                    
                    for (index, value) in normalizedNegative.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = centerY + (centerY * CGFloat(value)) // Below center
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(negativeColor, lineWidth: 2)
                
                // Negative fill
                Path { path in
                    guard !normalizedNegative.isEmpty else { return }
                    
                    let stepX = geometry.size.width / CGFloat(normalizedNegative.count - 1)
                    
                    path.move(to: CGPoint(x: 0, y: centerY))
                    
                    for (index, value) in normalizedNegative.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = centerY + (centerY * CGFloat(value))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    
                    path.addLine(to: CGPoint(x: geometry.size.width, y: centerY))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [negativeColor.opacity(0.3), negativeColor.opacity(0.1)]),
                        startPoint: .bottom,
                        endPoint: .center
                    )
                )
            }
        }
    }
}

#Preview {
    NotchStatsView()
        .frame(width: 400, height: 300)
        .background(Color.black)
}

// MARK: - Disk & Cleanup cards
//
// The three cards below mirror `UnifiedStatsCard`'s visual spec
// (padding 8, corner radius 8, white 8% fill, hover stroke) so the row
// reads as a natural extension of the Stats grid.
//
// Cleanup logic is delegated to `DiskCleaner`, which in turn shells out to
// the bundled `disk_maintenance.sh` v4.0.0 by zhyr, sourced from
// https://github.com/zhyr/LLM-based-Software-Devlopment-Kit-Suite

/// Card 1 of 3 — shows current root-volume disk usage (free / total / % used).
/// Read-only, no button.
struct DiskUsageStatsCard: View {
    @ObservedObject var diskCleaner: DiskCleaner
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.cyan)
                    .font(.caption)
                Text("磁盘占用")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
            }

            // Values section — fixed height so all 3 cards line up.
            Group {
                if let usage = diskCleaner.diskUsage {
                    Text(usage.usedPercentString)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("--")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)

            // Visual bar instead of a sparkline — disk usage is a single
            // snapshot, not a history, so a fill bar communicates it better
            // than a flat line.
            GeometryReader { geo in
                let pct = diskCleaner.diskUsage?.usedPercent ?? 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [pct < 0.8 ? .cyan : .orange, pct < 0.8 ? .blue : .red],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(pct))
                }
            }
            .frame(height: 36)

            // Footer line — free / total.
            Text(diskCleaner.diskUsage?.summary ?? "—")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHovered = $0 }
    }
}

/// Card 2 of 3 — "系统垃圾清理" — runs the GLOBAL half of disk_maintenance.sh
/// (Gradle / npm / Cargo / pip / Homebrew / Cursor / VSCode / Xcode DerivedData
/// / Simulator caches / Docker prune).
struct SystemCleanerCard: View {
    @ObservedObject var diskCleaner: DiskCleaner
    @State private var isHovered = false

    var body: some View {
        cleanerCard(
            title: "系统垃圾清理",
            icon: "trash.square",
            color: .orange,
            scope: .system,
            hoverHint: "Gradle · npm · Cargo · pip · Homebrew · Xcode"
        )
    }

    private func cleanerCard(
        title: String,
        icon: String,
        color: Color,
        scope: DiskCleaner.CleanupScope,
        hoverHint: String
    ) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
            }

            // Center: spinner while running, else freed-size or "—" .
            Group {
                if diskCleaner.isCleaning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity)
                } else if let result = diskCleaner.lastResult, result.scope == scope {
                    Text(result.summary)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(result.succeeded ? .green : .red)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("—")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)

            // Bottom action zone.
            Button(action: {
                diskCleaner.runCleanup(scope: scope)
            }) {
                Text(diskCleaner.isCleaning ? diskCleaner.lastProgressLine : "一键清理")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(diskCleaner.isCleaning ? 0.3 : 0.6))
                    )
            }
            .buttonStyle(.plain)
            .disabled(diskCleaner.isCleaning)
            .frame(height: 36)

            // Hover hint — what gets cleaned.
            Text(hoverHint)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHovered = $0 }
    }
}

/// Card 3 of 3 — "开发者垃圾清理" — runs the WORK half of disk_maintenance.sh
/// for `~/work` (.next / __pycache__ / tsbuildinfo / Rust target/debug /
/// Electron staging / logs / test-results / nested dist).
struct DevCleanerCard: View {
    @ObservedObject var diskCleaner: DiskCleaner
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text("开发者垃圾清理")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
            }

            Group {
                if diskCleaner.isCleaning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity)
                } else if let result = diskCleaner.lastResult, result.scope == .developer {
                    Text(result.summary)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(result.succeeded ? .green : .red)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("—")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)

            Button(action: {
                diskCleaner.runCleanup(scope: .developer)
            }) {
                Text(diskCleaner.isCleaning ? diskCleaner.lastProgressLine : "一键清理")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.purple.opacity(diskCleaner.isCleaning ? 0.3 : 0.6))
                    )
            }
            .buttonStyle(.plain)
            .disabled(diskCleaner.isCleaning)
            .frame(height: 36)

            Text(".next · __pycache__ · target · dist · logs")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHovered = $0 }
    }
}
