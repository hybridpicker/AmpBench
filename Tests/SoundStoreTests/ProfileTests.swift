import XCTest
@testable import SoundStore

/// What one device remembers about its store. Every test has settings, a keychain service and a state file of its
/// own, so the real store of this machine is never read or touched.
final class ProfileTests: XCTestCase {
    private func makeProfile(_ folder: URL) throws -> StoreProfile {
        let suite = "local.ampbench.store.tests.\(UUID().uuidString)"
        let service = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? StoreKeychain.setIdentity(nil, service: service)
            try? StoreKeychain.setPassword(nil, service: service)
        }
        return StoreProfile(defaults: defaults, keychainService: service,
                            stateURL: folder.appendingPathComponent("state.json"))
    }

    /// The keychain is missing on some build machines; the tests that need it are skipped there.
    private func withKey(_ profile: StoreProfile) throws {
        do {
            try profile.createKey()
        } catch {
            throw XCTSkip("no keychain here: \(error.localizedDescription)")
        }
    }

    func testANewDeviceHasNoStore() async throws {
        let profile = try makeProfile(try makeTemporaryFolder(self))
        XCTAssertNil(profile.settings)
        XCTAssertFalse(profile.hasKey)
        do {
            _ = try await profile.sync(folder: try makeTemporaryFolder(self, "sounds")) { _ in }
            XCTFail("a sync without a store must fail")
        } catch {
            XCTAssertEqual(error as? StoreProfileError, .notSetUp)
        }
    }

    func testSettingsAreKeptAndHoldNoSecret() throws {
        let profile = try makeProfile(try makeTemporaryFolder(self))
        let settings = StoreSettings(kind: .http, url: "https://example.org/sounds/", user: "made-up")
        profile.settings = settings
        XCTAssertEqual(profile.settings, settings)
        let stored = try XCTUnwrap(profile.defaults.data(forKey: StoreProfile.settingsKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("AGE-SECRET-KEY"))
    }

    func testAStoreWithoutAKeyDoesNotSync() async throws {
        let profile = try makeProfile(try makeTemporaryFolder(self))
        profile.settings = StoreSettings(kind: .folder, folderPath: try makeTemporaryFolder(self, "place").path)
        do {
            _ = try await profile.sync(folder: try makeTemporaryFolder(self, "sounds")) { _ in }
            XCTFail("a sync without a key must fail")
        } catch {
            XCTAssertEqual(error as? StoreProfileError, .noKey)
        }
    }

    func testAKeyIsNeverReplacedByANewOne() throws {
        let profile = try makeProfile(try makeTemporaryFolder(self))
        try withKey(profile)
        let first = try XCTUnwrap(profile.identity)
        XCTAssertThrowsError(try profile.createKey()) { XCTAssertEqual($0 as? StoreProfileError, .keyExists) }
        XCTAssertEqual(profile.identity, first)
    }

    func testTwoDevicesWithOneKeyShareTheirSounds() async throws {
        let place = try makeTemporaryFolder(self, "place")
        let mac = try makeProfile(try makeTemporaryFolder(self, "mac-state"))
        let pad = try makeProfile(try makeTemporaryFolder(self, "pad-state"))
        try withKey(mac)
        // The second device takes the first one's key, as the user enters it there.
        try pad.useKey(try XCTUnwrap(mac.identity).text)
        let settings = StoreSettings(kind: .folder, folderPath: place.path)
        mac.settings = settings
        pad.settings = settings

        let macSounds = try makeTemporaryFolder(self, "mac-sounds"), padSounds = try makeTemporaryFolder(self, "pad-sounds")
        try Data("a made-up sound".utf8).write(to: macSounds.appendingPathComponent("Lead.json"))
        let stored = try await mac.sync(folder: macSounds) { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(stored.uploaded, ["Lead.json"])
        XCTAssertNotNil(mac.lastSync)

        let fetched = try await pad.sync(folder: padSounds) { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(fetched.downloaded, ["Lead.json"])
        XCTAssertEqual(try Data(contentsOf: padSounds.appendingPathComponent("Lead.json")), Data("a made-up sound".utf8))
        // Nothing readable lies in the place: neither the name nor the content.
        for (name, data) in allFiles(in: place) {
            XCTAssertFalse(name.contains("Lead"))
            XCTAssertNil(data.range(of: Data("made-up sound".utf8)))
        }
    }

    func testDisconnectingKeepsTheKeyAndForgetsThePlace() throws {
        let profile = try makeProfile(try makeTemporaryFolder(self))
        try withKey(profile)
        profile.settings = StoreSettings(kind: .folder, folderPath: "/tmp/made-up")
        profile.lastSync = Date()
        profile.disconnect()
        XCTAssertNil(profile.settings)
        XCTAssertNil(profile.lastSync)
        XCTAssertTrue(profile.hasKey, "the key opens the store; disconnecting must not lose it")
    }
}
