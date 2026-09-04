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

/// Pins the "media controller defaults to Now Playing and does not auto-fallback
/// to Apple Music" invariants introduced when the per-app media source picker
/// (YouTube / Spotify / iTunes / Cider / …) was removed in favor of the
/// universal system Now Playing source.
///
/// Now Playing is the only controller that transparently supports third-party
/// players (网易云音乐 / QQ音乐 / 汽水音乐 / browsers). If a future change
/// re-introduces the macOS-version-gated fallback to Apple Music, Chinese
/// music apps would silently stop being controlled — these tests guard against
/// that regression.
final class NowPlayingControllerPreferenceTests: XCTestCase {

    /// Saved preference, restored in tearDown so these tests don't poison the
    /// shared `MusicManager.shared` for downstream tests in the same run.
    private var savedMediaController: MediaControllerType!

    override func setUp() {
        super.setUp()
        savedMediaController = Defaults[.mediaController]
    }

    override func tearDown() {
        Defaults[.mediaController] = savedMediaController
        super.tearDown()
    }

    // MARK: - Default value

    func testDefaultMediaControllerIsNowPlaying() {
        // This is the headline invariant: regardless of macOS version,
        // defaultMediaController must resolve to .nowPlaying. The old logic
        // returned .appleMusic on macOS 15.4+, which broke Chinese music apps.
        XCTAssertEqual(Defaults.Keys.defaultMediaController, .nowPlaying,
                       "defaultMediaController must be .nowPlaying on all macOS versions so third-party players (网易云/QQ/汽水) work out of the box.")
    }

    func testMediaControllerDefaultKeyUsesNowPlaying() {
        // The Defaults key initialiser reads `defaultMediaController` at first
        // launch. If a user has never set a preference, Defaults[.mediaController]
        // should equal .nowPlaying.
        // Note: this test can only assert the *current* value matches
        // defaultMediaController when no override is in place. We can't easily
        // reset UserDefaults in a unit test without disturbing other state, so
        // this is a softer check.
        XCTAssertEqual(Defaults.Keys.mediaController.defaultValue, Defaults.Keys.defaultMediaController,
                       "The Defaults key default must match defaultMediaController so first-launch users land on Now Playing.")
    }

    // MARK: - No auto-fallback to Apple Music

    func testSelectingNowPlayingActivatesNowPlayingControllerEvenWhenDeprecated() {
        // Simulate the user's explicit preference and exercise the same
        // resolution path production uses. We cannot directly flip
        // isNowPlayingDeprecated (it's set by a live MediaChecker probe), but
        // the production code path we changed no longer reads that flag when
        // the preference is .nowPlaying — so even on a build where the probe
        // returns true, .nowPlaying must still win when createController
        // succeeds for it.
        Defaults[.mediaController] = .nowPlaying
        let manager = MusicManager.shared
        manager.setActiveControllerBasedOnPreference()

        let active = manager.activeController
        XCTAssertNotNil(active,
                        "An active controller must be resolved for .nowPlaying.")
        let typeName = String(describing: type(of: active!))
        XCTAssertTrue(typeName.contains("NowPlayingController"),
                      "Active controller must be NowPlayingController when preference is .nowPlaying; got \(typeName). If this fails, the auto-fallback to Apple Music has been re-introduced and third-party players (网易云/QQ/汽水) will stop being controlled.")
    }

    // MARK: - Picker UI surfaces only Now Playing

    func testMediaControllerTypeEnumStillHasAllCasesForMigrationCompat() {
        // We did NOT remove the legacy cases (spotify / appleMusic / youtubeMusic
        // / amazonMusic / tidal / cider) from the enum — they're kept so a user
        // who previously selected one doesn't crash on decode. This test pins
        // that contract: if someone "cleans up" the enum by deleting the
        // legacy cases, this test will fail as a reminder to write a migration.
        let allCases: Set<MediaControllerType> = Set(MediaControllerType.allCases)
        let expected: Set<MediaControllerType> = [
            .nowPlaying, .appleMusic, .spotify, .youtubeMusic,
            .amazonMusic, .tidal, .cider
        ]
        XCTAssertEqual(allCases, expected,
                       "All legacy MediaControllerType cases must remain in the enum for migration compatibility. Removed cases would crash decoding of persisted Defaults[.mediaController] for existing users.")
    }

    // MARK: - Now Playing is a universal source

    func testNowPlayingIsCaseIterableFirst() {
        // Cosmetic but useful: .nowPlaying appears first in CaseIterable order,
        // so any UI that lists `MediaControllerType.allCases` (e.g. the onboarding
        // picker, if reintroduced) will show Now Playing at the top.
        XCTAssertEqual(MediaControllerType.allCases.first, .nowPlaying,
                       "Now Playing should be the first case in MediaControllerType.allCases for picker UI ordering.")
    }
}
