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
import XCTest

@testable import Atoll

/// Pins the "ScreenAssistant defaults to local Ollama with qwen3.5" invariants
/// introduced when the default AI provider was switched from Gemini to local
/// Ollama, and the local model list was made dynamic via /api/tags.
final class ScreenAssistantOllamaDefaultsTests: XCTestCase {

    // MARK: - Default provider

    func testDefaultAIProviderIsLocal() {
        XCTAssertEqual(Defaults.Keys.selectedAIProvider.defaultValue, .local,
                       "Default AI provider must be .local (Ollama) so the assistant works without a cloud API key.")
    }

    func testDefaultAIModelIsQwen35() {
        let model = Defaults.Keys.selectedAIModel.defaultValue
        XCTAssertEqual(model?.id, "qwen3.5:latest",
                       "Default AI model must be qwen3.5:latest so it matches a model the user is likely to have pulled.")
        XCTAssertEqual(model?.name, "Qwen 3.5 (local)")
    }

    func testLocalModelEndpointDefaultsToLocalhostOllama() {
        XCTAssertEqual(Defaults.Keys.localModelEndpoint.defaultValue, "http://localhost:11434",
                       "Local endpoint must default to Ollama's standard port.")
    }

    // MARK: - Dynamic model list merging

    func testLocalProviderIncludesQwen35ByDefault() {
        // The built-in (non-cached) local model list must include qwen3.5:latest
        // so the model picker shows something useful even before /api/tags is
        // fetched.
        let models = AIModelProvider.local.supportedModels
        let ids = models.map(\.id)
        XCTAssertTrue(ids.contains("qwen3.5:latest"),
                      "Local provider must list qwen3.5:latest by default; got \(ids)")
    }

    func testLocalProviderMergesCachedOllamaModels() throws {
        // Seed the cache with a fake model the way /api/tags would, then verify
        // it appears in supportedModels without losing the built-in defaults.
        let savedCache = Defaults[.localOllamaModels]
        defer { Defaults[.localOllamaModels] = savedCache }

        let fakeModel = AIModel(id: "fake-model:latest", name: "Fake Model", supportsThinking: false)
        Defaults[.localOllamaModels] = [fakeModel]

        let models = AIModelProvider.local.supportedModels
        let ids = models.map(\.id)

        XCTAssertTrue(ids.contains("fake-model:latest"),
                      "Cached Ollama models must be merged into the local provider's supportedModels list.")
        XCTAssertTrue(ids.contains("qwen3.5:latest"),
                      "Built-in defaults must still appear when cache is present.")
    }

    func testLocalProviderDoesNotDuplicateModelsAlreadyInDefaults() throws {
        // If /api/tags returns a model id that's already in the built-in list
        // (e.g. qwen3.5:latest), it must not be duplicated.
        let savedCache = Defaults[.localOllamaModels]
        defer { Defaults[.localOllamaModels] = savedCache }

        Defaults[.localOllamaModels] = [
            AIModel(id: "qwen3.5:latest", name: "Qwen 3.5 (cached)", supportsThinking: false),
            AIModel(id: "novel-model:latest", name: "Novel", supportsThinking: false)
        ]

        let models = AIModelProvider.local.supportedModels
        let qwenEntries = models.filter { $0.id == "qwen3.5:latest" }
        XCTAssertEqual(qwenEntries.count, 1,
                       "A model id present in both built-in defaults and the cache must appear exactly once; got \(qwenEntries.count).")
    }
}

/// Pins the App Launcher slot model invariants: exactly 10 slots, empty by
/// default, and the manager maintains the fixed count across mutations.
final class AppLauncherSlotsTests: XCTestCase {

    private var savedDefaultsSlots: [AppLauncherSlot]?
    private var savedManagerSlots: [AppLauncherSlot]?

    override func setUp() {
        super.setUp()
        // Snapshot both Defaults[.appLauncherSlots] and the live manager
        // slots. Tests that mutate the manager (assignApp/clearSlot tests)
        // write into the shared singleton, which would otherwise poison every
        // test that runs after them in the same process.
        savedDefaultsSlots = Defaults[.appLauncherSlots]
        savedManagerSlots = AppLauncherManager.shared.slots
        // Reset to a known state (10 empty slots) before every test so no
        // earlier-persisted data affects assertions like "slot 0 starts empty".
        let empty = AppLauncherSlot.defaultSlots
        Defaults[.appLauncherSlots] = empty
        AppLauncherManager.shared.slots = empty
    }

    override func tearDown() {
        if let savedDefaults = savedDefaultsSlots {
            Defaults[.appLauncherSlots] = savedDefaults
        }
        if let savedManager = savedManagerSlots {
            AppLauncherManager.shared.slots = savedManager
        }
        savedDefaultsSlots = nil
        savedManagerSlots = nil
        super.tearDown()
    }

    // MARK: - Default slot count

    func testDefaultSlotCountIsTen() {
        XCTAssertEqual(Defaults.Keys.appLauncherSlotCount, 10,
                       "App Launcher must expose exactly 10 slots by design.")
    }

    func testDefaultSlotsAreTenAndAllEmpty() {
        let slots = AppLauncherSlot.defaultSlots
        XCTAssertEqual(slots.count, 10)
        XCTAssertTrue(slots.allSatisfy(\.isEmpty),
                      "Default slots must all be empty so the launcher starts unconfigured.")
    }

    func testAppLauncherFeatureIsEnabledByDefault() {
        XCTAssertTrue(Defaults.Keys.enableAppLauncherFeature.defaultValue,
                      "App Launcher tab must be enabled by default so users see it on first launch.")
    }

    // MARK: - Slot model

    func testEmptySlotHasEmptyBundleId() {
        let slot = AppLauncherSlot()
        XCTAssertTrue(slot.isEmpty)
        XCTAssertEqual(slot.bundleId, "")
    }

    func testNonEmptySlotIsNotEmpty() {
        let slot = AppLauncherSlot(bundleId: "com.apple.Safari", appName: "Safari", appPath: "/Applications/Safari.app")
        XCTAssertFalse(slot.isEmpty)
    }

    func testDisplayNameFallsBackToAppName() {
        let slot = AppLauncherSlot(bundleId: "x", appName: "Safari", appPath: "/Applications/Safari.app")
        XCTAssertEqual(slot.displayName, "Safari")
    }

    func testDisplayNameUsesCustomLabelWhenProvided() {
        let slot = AppLauncherSlot(
            bundleId: "x", appName: "Safari", appPath: "/Applications/Safari.app",
            customLabel: "Web"
        )
        XCTAssertEqual(slot.displayName, "Web")
    }

    func testDisplayNameForEmptySlotIsPlaceholder() {
        // Empty slots should not show "Empty" — that would be visually noisy
        // in the notch. (The notch view uses an icon, not the placeholder text,
        // but the model invariant is still worth pinning.)
        let slot = AppLauncherSlot()
        XCTAssertEqual(slot.displayName, "Empty")
    }

    // MARK: - Manager fixed-count invariant

    func testManagerAlwaysReportsTenSlots() {
        // The shared manager maintains exactly 10 slots, even if persisted
        // state was somehow corrupted to a different count.
        let manager = AppLauncherManager.shared
        XCTAssertEqual(manager.slotCount, 10)
        XCTAssertEqual(manager.slots.count, 10)
    }

    // MARK: - assignApp (the logic the file picker feeds into)

    /// Regression guard for the "Choose app" flow. The file picker hands back
    /// a URL to a .app bundle; `assignApp(at:appURL:)` is what extracts the
    /// bundle id and name and writes them into the slot. If this logic breaks,
    /// the picker "works" (the panel appears) but the slot never fills in.
    ///
    /// Uses Finder.app as the test fixture because it ships with every macOS
    /// install, so the test is deterministic regardless of which apps the
    /// developer has personally installed.
    func testAssignAppPopulatesSlotWithBundleIdAndName() throws {
        let manager = AppLauncherManager.shared
        // Snapshot so we can restore — otherwise this test would mutate shared
        // state and poison other tests in the run.
        let savedSlots = manager.slots

        // Use Finder.app — guaranteed to exist on every macOS install.
        let finderURL = try XCTUnwrap(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"),
            "Finder.app must exist on every macOS install — test fixture invariant."
        )

        // Sanity: the URL should point at a .app bundle.
        XCTAssertEqual(finderURL.pathExtension, "app")

        // Slot 0 starts empty (defaultSlots are all empty).
        XCTAssertTrue(manager.slots[0].isEmpty)

        manager.assignApp(at: 0, appURL: finderURL)

        let slot = manager.slots[0]
        XCTAssertFalse(slot.isEmpty, "Slot 0 must be non-empty after assignApp.")
        XCTAssertEqual(slot.bundleId, "com.apple.finder",
                       "assignApp must extract the bundle identifier from the .app bundle.")
        XCTAssertEqual(slot.appPath, finderURL.path,
                       "assignApp must store the absolute path so launch-by-path works later.")
        XCTAssertFalse(slot.appName.isEmpty,
                       "assignApp must populate appName (from CFBundleName or the filename).")

        // Restore.
        manager.slots = savedSlots
    }

    /// `assignApp` must be a no-op (not a crash) when given a URL that isn't a
    /// valid bundle — e.g. the user picks a folder, or the .app was deleted
    /// between the picker and the callback.
    func testAssignAppWithInvalidBundleIsNoOp() throws {
        let manager = AppLauncherManager.shared
        let savedSlots = manager.slots

        // A directory is not a bundle.
        let notABundle = URL(fileURLWithPath: "/Applications")
        let slotBefore = manager.slots[1]
        manager.assignApp(at: 1, appURL: notABundle)

        XCTAssertEqual(manager.slots[1], slotBefore,
                       "assignApp with a non-bundle URL must leave the slot untouched (no crash, no partial write).")

        manager.slots = savedSlots
    }

    /// `assignApp` must be a no-op for out-of-range indices — defensive
    /// boundary check.
    func testAssignAppOutOfRangeIndexIsNoOp() throws {
        let manager = AppLauncherManager.shared
        let savedSlots = manager.slots

        let finderURL = try XCTUnwrap(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        )
        manager.assignApp(at: 99, appURL: finderURL)  // out of range
        manager.assignApp(at: -1, appURL: finderURL)  // negative

        XCTAssertEqual(manager.slots, savedSlots,
                       "assignApp with an out-of-range index must not mutate slots.")

        manager.slots = savedSlots
    }

    /// `clearSlot` must reset a slot back to empty without disturbing the
    /// slot's identity (so SwiftUI ForEach by id stays stable).
    func testClearSlotResetsToEmptyButKeepsIdentity() throws {
        let manager = AppLauncherManager.shared
        let savedSlots = manager.slots

        let finderURL = try XCTUnwrap(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        )
        manager.assignApp(at: 2, appURL: finderURL)
        let slotIdAfterAssign = manager.slots[2].id
        XCTAssertFalse(manager.slots[2].isEmpty)

        manager.clearSlot(at: 2)

        XCTAssertTrue(manager.slots[2].isEmpty, "Slot must be empty after clearSlot.")
        XCTAssertEqual(manager.slots[2].id, slotIdAfterAssign,
                       "clearSlot must preserve the slot's UUID so SwiftUI ForEach identity stays stable across clear/re-assign.")

        manager.slots = savedSlots
    }
}
