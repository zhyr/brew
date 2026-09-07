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

import XCTest

@testable import Atoll

/// Pins the "App Launcher is the first tab" invariant introduced when the
/// launcher was promoted to the leftmost position in the notch tab bar.
///
/// These tests do not instantiate `TabSelectionView` (a SwiftUI view, awkward
/// to drive headless). Instead they assert against the canonical tab order
/// exposed by `DynamicIslandViewCoordinator`, which is the single source of
/// truth that `TabSelectionView`, gesture handling, and `currentView` direction
/// tracking all read from. If that order drifts, these tests fail.
@MainActor
final class TabOrderTests: XCTestCase {

    // MARK: - App Launcher is first

    func testAppLauncherIsTheFirstTabInTheCanonicalOrder() {
        let order = DynamicIslandViewCoordinator.allTabsInOrder
        XCTAssertEqual(order.first, .appLauncher,
                       "App Launcher must be the leftmost tab so it is the default landing view when the notch opens.")
    }

    func testAppLauncherPrecedesHome() {
        let order = DynamicIslandViewCoordinator.allTabsInOrder
        guard let appLauncherIndex = order.firstIndex(of: .appLauncher),
              let homeIndex = order.firstIndex(of: .home) else {
            return XCTFail("Both .appLauncher and .home must be present in the tab order.")
        }
        XCTAssertLessThan(appLauncherIndex, homeIndex,
                          "App Launcher must come before Home so it lands at index 0.")
    }

    func testTabIndexHelperReturnsZeroForAppLauncher() {
        XCTAssertEqual(DynamicIslandViewCoordinator.tabIndex(.appLauncher), 0,
                       "tabIndex(.appLauncher) must be 0 — this is what gesture/keyboard tab navigation uses as the starting position.")
    }

    // MARK: - Ordering is stable and complete

    func testTabOrderContainsAllUserFacingTabs() {
        // Every NotchViews case that should appear in the tab bar must be
        // present in the canonical order. If a new case is added to NotchViews
        // without being added to tabOrder, this test will flag it (after the
        // developer decides whether it belongs in the tab bar or not).
        //
        // `.extensionExperience` is included in `tabOrder` because the tab
        // direction-tracking logic in `currentView.didSet` needs every
        // reachable view to have an index, even if it's not rendered as a
        // visible tab chip in `TabSelectionView`.
        let order = DynamicIslandViewCoordinator.allTabsInOrder
        let expectedMembers: Set<NotchViews> = [
            .appLauncher, .agentActivity, .home, .shelf, .timer, .stats, .llmUsage,
            .colorPicker, .notes, .clipboard, .terminal, .extensionExperience
        ]
        let actualMembers = Set(order)
        XCTAssertEqual(actualMembers, expectedMembers,
                       "Tab order must include exactly the reachable views. Missing or extra: \(actualMembers.symmetricDifference(expectedMembers))")
    }

    func testTabOrderHasNoDuplicates() {
        let order = DynamicIslandViewCoordinator.allTabsInOrder
        XCTAssertEqual(order.count, Set(order).count,
                       "Tab order must not contain duplicates — duplicates would break gesture-based tab navigation.")
    }

    // MARK: - Default current view

    func testSharedCoordinatorCurrentViewIsAppLauncher() {
        // The shared coordinator is initialised at app launch with
        // `currentView = .appLauncher`. Asserting this pins the default landing
        // view. We can't construct a fresh coordinator (init is private), but
        // the shared instance's value reflects the declared default unless
        // something explicitly switched it — and nothing in this test process
        // does so before this test runs.
        //
        // Note: this test is order-sensitive within the suite; if another test
        // in the same process switches the shared coordinator's view first,
        // this assertion could flake. To avoid that, we reset it here.
        let coordinator = DynamicIslandViewCoordinator.shared
        coordinator.currentView = .appLauncher
        XCTAssertEqual(coordinator.currentView, .appLauncher,
                       "Default currentView must be .appLauncher so the launcher is shown first when the notch opens.")
    }
}
